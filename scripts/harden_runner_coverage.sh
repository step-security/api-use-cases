#!/usr/bin/env bash
#
# harden_runner_coverage.sh
#
# Generates CSV report(s) showing harden-runner coverage —
# monitored vs. unmonitored workflow runs over a date range —
# across one or more GitHub orgs.
#
# Usage:
#   ./harden_runner_coverage.sh --tenant <tenant> --token <token> [--org <org>] [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD] [--output-prefix <prefix>]
#   ./harden_runner_coverage.sh --org <github-org> --token <token> [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD] [--output-prefix <prefix>]
#
# When --tenant is provided without --org, the report covers every
# org in the tenant. When --org is provided (with or without
# --tenant), the report is scoped to that single org.
#
# Two CSVs are produced:
#   <prefix>_daily.csv      — one row per (owner, date) with run counts and coverage %.
#   <prefix>_workflows.csv  — one row per (owner, repo, workflow) for the day(s) that
#                             include a per-repo breakdown (typically the end date).
#
# Requirements: curl, jq

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1"
OUTPUT_PREFIX="harden_runner_coverage"
TENANT=""
ORG=""
TOKEN=""
START_DATE=""
END_DATE=""

usage() {
  echo "Usage: $0 (--tenant <tenant> | --org <org>) --token <token> [--org <org>] [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD] [--output-prefix <prefix>]"
  echo ""
  echo "  --tenant         Tenant identifier (reports across all orgs in the tenant)"
  echo "  --org            GitHub organization name (scopes the report to a single org)"
  echo "  --token          API bearer token"
  echo "  --start-date     Start date (YYYY-MM-DD). Defaults to 7 days before --end-date."
  echo "  --end-date       End date (YYYY-MM-DD). Defaults to today (UTC)."
  echo "  --output-prefix  Output file prefix (default: harden_runner_coverage)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)        TENANT="$2"; shift 2 ;;
    --org)           ORG="$2"; shift 2 ;;
    --token)         TOKEN="$2"; shift 2 ;;
    --start-date)    START_DATE="$2"; shift 2 ;;
    --end-date)      END_DATE="$2"; shift 2 ;;
    --output-prefix) OUTPUT_PREFIX="$2"; shift 2 ;;
    *)               usage ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  usage
fi

if [[ -z "$TENANT" && -z "$ORG" ]]; then
  usage
fi

# ── 1. Default the date range ──────────────────────────────────────

if [[ -z "$END_DATE" ]]; then
  END_DATE=$(date -u +%Y-%m-%d)
fi

if [[ -z "$START_DATE" ]]; then
  if date -u -d "1970-01-01" +%Y-%m-%d >/dev/null 2>&1; then
    # GNU date (Linux / GitHub-hosted runners)
    START_DATE=$(date -u -d "${END_DATE} - 7 days" +%Y-%m-%d)
  else
    # BSD date (macOS)
    START_DATE=$(date -u -j -f %Y-%m-%d "$END_DATE" -v-7d +%Y-%m-%d)
  fi
fi

DAILY_CSV="${OUTPUT_PREFIX}_daily.csv"
WORKFLOWS_CSV="${OUTPUT_PREFIX}_workflows.csv"

# ── 2. Set up working directory ────────────────────────────────────

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ── 3. Determine which orgs to process ─────────────────────────────

ORGS=()
if [[ -n "$ORG" ]]; then
  ORGS=("$ORG")
  CONTEXT_INFO="organization '${ORG}'"
else
  echo "Fetching organizations for tenant '${TENANT}'..."

  ORGS_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: $TOKEN" \
    "${BASE_URL}/${TENANT}/github/organizations")

  HTTP_CODE=$(echo "$ORGS_RESPONSE" | tail -1)
  ORGS_BODY=$(echo "$ORGS_RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "Error: HTTP $HTTP_CODE fetching organizations for tenant '${TENANT}'" >&2
    echo "$ORGS_BODY" >&2
    exit 1
  fi

  ORG_LIST=$(echo "$ORGS_BODY" | jq -r '
    (if type == "object" then
       (.organizations // .result // .data // [])
     elif type == "array" then
       .
     else
       []
     end)
    | if type == "array" then
        .[] | if type == "string" then . elif type == "object" then (.organization // .owner // .name // empty) else empty end
      else
        empty
      end
  ' 2>/dev/null)

  if [[ -z "$ORG_LIST" ]]; then
    echo "No organizations found for tenant '${TENANT}'." >&2
    exit 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] && ORGS+=("$line")
  done <<< "$ORG_LIST"

  CONTEXT_INFO="tenant '${TENANT}' (${#ORGS[@]} orgs)"
  echo "Found ${#ORGS[@]} orgs: ${ORGS[*]}"
fi

# ── 4. Write CSV headers ───────────────────────────────────────────

echo "owner,date,monitored_runs,unmonitored_runs,total_runs,coverage_percentage,trend" > "$DAILY_CSV"
echo "owner,date,repo,workflow_path,workflow_name,monitored_runs,unmonitored_runs,total_runs,coverage_percentage" > "$WORKFLOWS_CSV"

# ── 5. Fetch coverage per org and append rows ──────────────────────

TOTAL_DAILY=0
TOTAL_WORKFLOW=0

for CURRENT_ORG in "${ORGS[@]}"; do
  echo ""
  echo "Processing org: ${CURRENT_ORG} (${START_DATE} → ${END_DATE})"

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: $TOKEN" \
    "${BASE_URL}/github/${CURRENT_ORG}/actions/harden-runner-coverage?start_date=${START_DATE}&end_date=${END_DATE}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "  Warning: HTTP $HTTP_CODE — skipping." >&2
    continue
  fi

  # Daily rows: one per date key returned by the API.
  DAILY_ROWS=$(echo "$BODY" | jq -r --arg owner "$CURRENT_ORG" '
    to_entries
    | sort_by(.key)
    | .[]
    | [$owner, .key,
       (.value.monitored_runs   // 0),
       (.value.unmonitored_runs // 0),
       (.value.total_runs       // 0),
       (.value.coverage_percentage // ""),
       (.value.trend              // "")]
    | @csv
  ')

  if [[ -n "$DAILY_ROWS" ]]; then
    echo "$DAILY_ROWS" >> "$DAILY_CSV"
    ORG_DAILY=$(echo "$DAILY_ROWS" | wc -l | tr -d ' ')
    TOTAL_DAILY=$((TOTAL_DAILY + ORG_DAILY))
    echo "  Daily rows: $ORG_DAILY"
  fi

  # Per-workflow rows: only days that include a repositories breakdown.
  WORKFLOW_ROWS=$(echo "$BODY" | jq -r --arg owner "$CURRENT_ORG" '
    to_entries
    | map(select(.value | has("repositories")))
    | .[]
    | . as $day
    | $day.value.repositories
    | to_entries[]
    | . as $repo
    | ($repo.value.workflows // {})
    | to_entries[]
    | [$owner, $day.key, $repo.key, .key,
       (.value.workflow_name      // ""),
       (.value.monitored_runs     // 0),
       (.value.unmonitored_runs   // 0),
       (.value.total_runs         // 0),
       (.value.coverage_percentage // "")]
    | @csv
  ')

  if [[ -n "$WORKFLOW_ROWS" ]]; then
    echo "$WORKFLOW_ROWS" >> "$WORKFLOWS_CSV"
    ORG_WF=$(echo "$WORKFLOW_ROWS" | wc -l | tr -d ' ')
    TOTAL_WORKFLOW=$((TOTAL_WORKFLOW + ORG_WF))
    echo "  Workflow rows: $ORG_WF"
  fi
done

# ── 6. Summary ─────────────────────────────────────────────────────

echo ""
echo "=== HARDEN-RUNNER COVERAGE SUMMARY for ${CONTEXT_INFO} ==="
echo "Date range:     ${START_DATE} → ${END_DATE}"
echo "Daily CSV:      ${DAILY_CSV}  (${TOTAL_DAILY} rows)"
echo "Workflows CSV:  ${WORKFLOWS_CSV}  (${TOTAL_WORKFLOW} rows)"

if [[ "$TOTAL_DAILY" -gt 0 ]]; then
  echo ""
  echo "Per-org coverage on end date (${END_DATE}):"
  awk -F',' -v end_date="\"${END_DATE}\"" '
    NR > 1 && $2 == end_date {
      owner=$1; gsub(/"/, "", owner)
      mon=$3; unmon=$4; tot=$5; cov=$6
      printf "  %-30s monitored=%s, unmonitored=%s, total=%s, coverage=%s%%\n", owner, mon, unmon, tot, cov
    }
  ' "$DAILY_CSV"
fi
