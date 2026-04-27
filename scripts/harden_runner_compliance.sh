#!/usr/bin/env bash
#
# harden_runner_compliance.sh
#
# Generates a CSV compliance report showing which workflow jobs
# across one or more GitHub orgs (in a StepSecurity tenant) are
# missing harden-runner.
#
# Usage:
#   ./harden_runner_compliance.sh --tenant <tenant> --token <stepsecurity-bearer-token> [--org <org>] [--failed-only] [--output <file.csv>] [--parallel <n>]
#   ./harden_runner_compliance.sh --org <github-org> --token <stepsecurity-bearer-token> [--failed-only] [--output <file.csv>] [--parallel <n>]
#
# When --tenant is provided without --org, the report is generated for
# every org in the tenant. When --org is provided (with or without
# --tenant), the report is scoped to that single org.
#
# Requirements: curl, jq

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1"
CONTROLS=("GitHubHostedRunnerShouldBeHardened" "SelfHostedRunnerShouldBeHardened")
OUTPUT="harden_runner_report.csv"
FAILED_ONLY=false
PARALLEL=100
TENANT=""
ORG=""
TOKEN=""

usage() {
  echo "Usage: $0 (--tenant <tenant> | --org <org>) --token <stepsecurity-token> [--org <org>] [--failed-only] [--output <file>] [--parallel <n>]"
  echo ""
  echo "  --tenant       StepSecurity tenant identifier (reports across all orgs in the tenant)"
  echo "  --org          GitHub organization name (scopes the report to a single org)"
  echo "  --token        StepSecurity API bearer token"
  echo "  --failed-only  Only include non-compliant jobs"
  echo "  --output       Output CSV file (default: harden_runner_report.csv)"
  echo "  --parallel     Number of concurrent API requests (default: 100)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)     TENANT="$2"; shift 2 ;;
    --org)        ORG="$2"; shift 2 ;;
    --token)      TOKEN="$2"; shift 2 ;;
    --failed-only) FAILED_ONLY=true; shift ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --parallel)   PARALLEL="$2"; shift 2 ;;
    *)            usage ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  usage
fi

if [[ -z "$TENANT" && -z "$ORG" ]]; then
  usage
fi

# ── 1. Set up working directory ────────────────────────────────────

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

ALL_CHECKS="$TMPDIR_WORK/all_checks.json"
echo "[]" > "$ALL_CHECKS"

# ── 2. Determine which orgs to process ─────────────────────────────

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

# ── 3. Create helper script for parallel per-repo fetching ────────

cat > "$TMPDIR_WORK/fetch_control.sh" << 'HELPER_EOF'
#!/usr/bin/env bash
REPO="$1"
CONTROL="$2"
BASE_URL="$3"
ORG="$4"
TOKEN="$5"
OUTDIR="$6"

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: $TOKEN" \
  "${BASE_URL}/github/${ORG}/${REPO}/actions/controls/${CONTROL}" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -eq 200 ]]; then
  ENTRY_COUNT=$(echo "$BODY" | jq 'length' 2>/dev/null || echo "0")
  if [[ "$ENTRY_COUNT" -gt 0 ]]; then
    SAFE_NAME=$(echo "${REPO}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    echo "$BODY" > "${OUTDIR}/${SAFE_NAME}.json"
  fi
fi
HELPER_EOF
chmod +x "$TMPDIR_WORK/fetch_control.sh"

# ── 4. Process each org ────────────────────────────────────────────

for CURRENT_ORG in "${ORGS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "Processing org: ${CURRENT_ORG}"
  echo "════════════════════════════════════════════════════════════════"

  ORG_WORK="$TMPDIR_WORK/orgs/$(echo "$CURRENT_ORG" | sed 's/[^a-zA-Z0-9._-]/_/g')"
  mkdir -p "$ORG_WORK"

  # Fetch repository list for this org
  echo "Fetching repository list for '${CURRENT_ORG}'..."

  REPOS_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: $TOKEN" \
    "${BASE_URL}/github/${CURRENT_ORG}/actions/security-summary")

  HTTP_CODE=$(echo "$REPOS_RESPONSE" | tail -1)
  REPOS_BODY=$(echo "$REPOS_RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "  Warning: HTTP $HTTP_CODE fetching repository list for '${CURRENT_ORG}' - skipping." >&2
    continue
  fi

  echo "$REPOS_BODY" | jq -r '.[].Repo | select(. != "#all#")' > "$ORG_WORK/repos.txt"
  REPO_COUNT=$(wc -l < "$ORG_WORK/repos.txt" | tr -d ' ')
  echo "  Found $REPO_COUNT repositories"

  if [[ "$REPO_COUNT" -eq 0 ]]; then
    continue
  fi

  for CONTROL in "${CONTROLS[@]}"; do
    if [[ "$CONTROL" == "SelfHostedRunnerShouldBeHardened" ]]; then
      RUNNER_TYPE="Self-Hosted"
    else
      RUNNER_TYPE="GitHub-Hosted"
    fi

    CONTROL_DIR="$ORG_WORK/$CONTROL"
    mkdir -p "$CONTROL_DIR"

    echo ""
    echo "  Fetching ${CONTROL} across ${REPO_COUNT} repos (${PARALLEL} parallel)..."

    tr '\n' '\0' < "$ORG_WORK/repos.txt" | \
      xargs -0 -P "$PARALLEL" -I {} \
      "$TMPDIR_WORK/fetch_control.sh" {} "$CONTROL" "$BASE_URL" "$CURRENT_ORG" "$TOKEN" "$CONTROL_DIR"

    # Merge all per-repo JSON files for this control
    shopt -s nullglob
    REPO_FILES=("$CONTROL_DIR"/*.json)
    shopt -u nullglob

    if [[ ${#REPO_FILES[@]} -gt 0 ]]; then
      MERGED=$(jq -s 'add' "${REPO_FILES[@]}")
      ENTRY_COUNT=$(echo "$MERGED" | jq 'length')
      echo "    Found $ENTRY_COUNT job entries from ${#REPO_FILES[@]} repos"

      TRANSFORMED=$(echo "$MERGED" | jq --arg owner "$CURRENT_ORG" \
        --arg control "$CONTROL" \
        --arg runner_type "$RUNNER_TYPE" \
        --argjson failed_only "$FAILED_ONLY" '
        [.[] | {
          owner: $owner,
          repo: (.repo // ""),
          workflow: (.workflow // ""),
          job: (.job // ""),
          control: $control,
          runner_type: $runner_type,
          status: (.status // ""),
          job_labels: ((.jobLabels // []) | join(", ")),
          workflow_url: (.workflowHTMLURL // ""),
          job_url: (.jobHTMLURL // ""),
          first_failed: (.firstFailedCheckTimeStamp // ""),
          last_failed: (.mostRecentFailedCheckTimeStamp // ""),
          last_checked: (.checkTimeStamp // "")
        }]
        | if $failed_only then [.[] | select(.status == "Failed")]
          else .
          end
      ')

      ALL_MERGED=$(jq -s '.[0] + .[1]' "$ALL_CHECKS" <(echo "$TRANSFORMED"))
      echo "$ALL_MERGED" > "$ALL_CHECKS"
    else
      echo "    Found 0 job entries"
    fi
  done
done

# ── 5. Sort and write CSV ────────────────────────────────────────────

TOTAL=$(jq 'length' "$ALL_CHECKS")

if [[ "$TOTAL" -eq 0 ]]; then
  echo ""
  echo "No results found."
  exit 0
fi

# Sort by owner, repo, workflow, job and write CSV
echo "owner,repo,workflow,job,control,runner_type,status,job_labels,workflow_url,job_url,first_failed,last_failed,last_checked" > "$OUTPUT"

jq -r '
  sort_by(.owner, .repo, .workflow, .job)[]
  | [.owner, .repo, .workflow, .job, .control, .runner_type, .status, .job_labels, .workflow_url, .job_url, .first_failed, .last_failed, .last_checked]
  | @csv
' "$ALL_CHECKS" >> "$OUTPUT"

echo ""
echo "Wrote $TOTAL entries to $OUTPUT"

# ── 6. Summary ───────────────────────────────────────────────────────

SUMMARY=$(jq '
  {
    total:      length,
    orgs:       ([.[].owner] | unique | length),
    repos:      ([.[] | "\(.owner)/\(.repo)"] | unique | length),
    passed:     ([.[] | select(.status == "Passed")] | length),
    failed:     ([.[] | select(.status == "Failed")] | length),
    suppressed: ([.[] | select(.status == "Suppressed")] | length)
  }
' "$ALL_CHECKS")

echo ""
echo "=== COMPLIANCE SUMMARY for ${CONTEXT_INFO} ==="
echo "Total orgs:        $(echo "$SUMMARY" | jq '.orgs')"
echo "Total repos:       $(echo "$SUMMARY" | jq '.repos')"
echo "Total job checks:  $(echo "$SUMMARY" | jq '.total')"
echo "  Passed:          $(echo "$SUMMARY" | jq '.passed')"
echo "  Failed:          $(echo "$SUMMARY" | jq '.failed')"
echo "  Suppressed:      $(echo "$SUMMARY" | jq '.suppressed')"

# Per-org breakdown
echo ""
echo "Per-org breakdown:"
jq -r '
  group_by(.owner)
  | sort_by(.[0].owner)
  | .[]
  | "  \(.[0].owner): total=\(length), passed=\([.[] | select(.status == "Passed")] | length), failed=\([.[] | select(.status == "Failed")] | length), suppressed=\([.[] | select(.status == "Suppressed")] | length)"
' "$ALL_CHECKS"

# List repos with failures
FAILED_REPOS=$(jq -r '
  [.[] | select(.status == "Failed")]
  | group_by(.owner + "/" + .repo)
  | sort_by(.[0].owner, .[0].repo)
  | .[]
  | "  \(.[0].owner)/\(.[0].repo): \(length) failing job(s)"
' "$ALL_CHECKS")

if [[ -n "$FAILED_REPOS" ]]; then
  FAILED_REPO_COUNT=$(jq '[.[] | select(.status == "Failed") | "\(.owner)/\(.repo)"] | unique | length' "$ALL_CHECKS")
  echo ""
  echo "Repos with non-compliant jobs ($FAILED_REPO_COUNT):"
  echo "$FAILED_REPOS"
fi
