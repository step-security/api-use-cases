#!/usr/bin/env bash
#
# match_action_iocs.sh
#
# Scans workflow runs in a time window across a StepSecurity tenant
# (or single org) and matches the actions actually executed (by commit
# SHA) against a user-provided IOC CSV. Useful when a known supply
# chain incident publishes a list of compromised <action, sha> pairs
# and you need to check which runs in your tenant actually executed
# those compromised commits.
#
# Usage:
#   ./match_action_iocs.sh --tenant <tenant> --token <stepsecurity-token> --ioc-csv <path> --days <n> [--output <file>] [--parallel <n>]
#   ./match_action_iocs.sh --org <org>       --token <stepsecurity-token> --ioc-csv <path> --start-time <epoch> [--end-time <epoch>]
#
# The StepSecurity API caps start_time at 90 days in the past.
#
# IOC CSV format (header row required):
#   action,sha,label
#   tj-actions/changed-files,0e58ed867288ce82bdcabd8c25aaaa0c4ee1c8b4,CVE-2025-30066
#   ,abcdef0123456789abcdef0123456789abcdef01,Shai-Hulud-Wave1
#
#   - sha is REQUIRED (matched against actions_info[].sha, case-insensitive).
#   - action is OPTIONAL: if present, action AND sha must both match.
#                         if empty, any usage of that sha matches.
#   - label is OPTIONAL: free-form, carried into the output.
#
# Requirements: curl, jq, awk

set -euo pipefail

API_BASE="https://agent.api.stepsecurity.io/v1"
OUTPUT="workflow_run_ioc_matches.csv"
PARALLEL=20
TENANT=""
ORG=""
TOKEN=""
IOC_CSV=""
DAYS=""
START_TIME=""
END_TIME=""

usage() {
  cat >&2 <<EOF
Usage: $0 (--tenant <tenant> | --org <org>) --token <token> --ioc-csv <path> (--days <n> | --start-time <epoch> [--end-time <epoch>]) [--output <file>] [--parallel <n>]

Required:
  --tenant         StepSecurity tenant identifier (scans every org in the tenant)
  --org            GitHub organization name (scopes the scan to a single org)
  --token          StepSecurity API bearer token
  --ioc-csv        CSV file with IOC entries (header: action,sha,label)

Time window (one of):
  --days           Look back N days (max 90)
  --start-time     Lower bound (Unix epoch seconds, max 90 days ago)
  --end-time       Upper bound (Unix epoch seconds, defaults to now)

Optional:
  --output         Output CSV file (default: workflow_run_ioc_matches.csv)
  --parallel       Concurrent run-detail fetches (default: 20)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)      TENANT="$2"; shift 2 ;;
    --org)         ORG="$2"; shift 2 ;;
    --token)       TOKEN="$2"; shift 2 ;;
    --ioc-csv)     IOC_CSV="$2"; shift 2 ;;
    --days)        DAYS="$2"; shift 2 ;;
    --start-time)  START_TIME="$2"; shift 2 ;;
    --end-time)    END_TIME="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    --parallel)    PARALLEL="$2"; shift 2 ;;
    *)             usage ;;
  esac
done

if [[ -z "$TOKEN" || -z "$IOC_CSV" ]]; then usage; fi
if [[ -z "$TENANT" && -z "$ORG" ]]; then usage; fi
if [[ ! -f "$IOC_CSV" ]]; then
  echo "Error: IOC CSV not found: $IOC_CSV" >&2; exit 1
fi

NOW=$(date +%s)

if [[ -n "$DAYS" ]]; then
  if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [[ "$DAYS" -lt 1 ]]; then
    echo "Error: --days must be a positive integer" >&2; exit 1
  fi
  START_TIME=$((NOW - DAYS * 86400))
  END_TIME=${END_TIME:-$NOW}
elif [[ -n "$START_TIME" ]]; then
  END_TIME=${END_TIME:-$NOW}
else
  echo "Error: must provide either --days or --start-time" >&2; usage
fi

# Server enforces a hard 90-day cap on start_time. Clamp with a 60-second
# safety buffer so a slow request doesn't trip the boundary.
NINETY_DAYS_AGO=$((NOW - 90 * 86400 + 60))
if [[ "$START_TIME" -lt "$NINETY_DAYS_AGO" ]]; then
  echo "Error: start_time is more than 90 days ago. The StepSecurity API rejects" >&2
  echo "       windows older than 90 days. Please choose a shorter window." >&2
  exit 1
fi
if [[ "$END_TIME" -lt "$START_TIME" ]]; then
  echo "Error: --end-time ($END_TIME) is before --start-time ($START_TIME)." >&2; exit 1
fi

START_ISO=$(date -u -r "$START_TIME" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$START_TIME" "+%Y-%m-%dT%H:%M:%SZ")
END_ISO=$(date -u -r "$END_TIME" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$END_TIME" "+%Y-%m-%dT%H:%M:%SZ")
echo "Time window: ${START_ISO} → ${END_ISO}"

# ── Build IOC index ────────────────────────────────────────────────

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

IOC_JSON="$TMPDIR_WORK/ioc.json"

awk -F',' '
  function trim(s) { gsub(/^[ \t\r"]+|[ \t\r"]+$/, "", s); return s }
  NR==1 { for (i=1; i<=NF; i++) hdr[i] = tolower(trim($i)); next }
  NF >= 1 {
    obj = "{"; sep = ""
    for (i=1; i<=NF; i++) {
      key = hdr[i]; if (key == "") continue
      val = trim($i); gsub(/\\/, "\\\\", val); gsub(/"/, "\\\"", val)
      obj = obj sep "\"" key "\":\"" val "\""; sep = ","
    }
    obj = obj "}"
    print obj
  }
' "$IOC_CSV" | jq -s '
  map({
    action: ((.action // "") | ascii_downcase),
    sha:    ((.sha    // "") | ascii_downcase),
    label:  (.label  // "")
  })
  | map(select(.sha != ""))
' > "$IOC_JSON"

IOC_COUNT=$(jq 'length' "$IOC_JSON")
if [[ "$IOC_COUNT" -eq 0 ]]; then
  echo "Error: IOC CSV has no usable rows (need 'sha' column with non-empty values)." >&2
  exit 1
fi

UNIQUE_SHAS=$(jq '[.[] | .sha] | unique | length' "$IOC_JSON")
echo "Loaded $IOC_COUNT IOC entries ($UNIQUE_SHAS unique SHAs)"

# ── Determine orgs ────────────────────────────────────────────────

ORGS=()
if [[ -n "$ORG" ]]; then
  ORGS=("$ORG")
  CONTEXT_INFO="organization '${ORG}'"
else
  echo "Fetching organizations for tenant '${TENANT}'..."
  ORGS_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "${API_BASE}/${TENANT}/github/organizations")
  HTTP_CODE=$(echo "$ORGS_RESPONSE" | tail -1)
  ORGS_BODY=$(echo "$ORGS_RESPONSE" | sed '$d')
  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "Error: HTTP $HTTP_CODE fetching organizations for tenant '${TENANT}'" >&2
    echo "$ORGS_BODY" >&2; exit 1
  fi
  while IFS= read -r line; do [[ -n "$line" ]] && ORGS+=("$line"); done < <(echo "$ORGS_BODY" | jq -r '
    (if type == "object" then (.organizations // .result // .data // []) elif type == "array" then . else [] end)
    | if type == "array" then .[] | if type == "string" then . elif type == "object" then (.organization // .owner // .name // empty) else empty end else empty end
  ')
  CONTEXT_INFO="tenant '${TENANT}' (${#ORGS[@]} orgs)"
  echo "Found ${#ORGS[@]} orgs: ${ORGS[*]}"
fi

# ── Helper: per-run detail fetch + IOC match ──────────────────────

cat > "$TMPDIR_WORK/match_run.sh" << 'HELPER_EOF'
#!/usr/bin/env bash
OWNER="$1"; REPO="$2"; RUN_ID="$3"; API_BASE="$4"; TOKEN="$5"; IOC_JSON="$6"; OUTDIR="$7"

RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "${API_BASE}/github/${OWNER}/${REPO}/actions/runs/${RUN_ID}" 2>/dev/null)
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ne 200 ]]; then exit 0; fi

OUT="${OUTDIR}/${OWNER}__${REPO}__${RUN_ID}.jsonl"

echo "$BODY" | jq -c --slurpfile ioc "$IOC_JSON" '
  ($ioc[0]) as $iocs_arr
  | ($iocs_arr
     | map({key: .sha, value: .})
     | group_by(.key)
     | map({key: .[0].key, value: map(.value)})
     | from_entries) as $sha_map
  | . as $run
  # repo from detail response is "owner/repo" — strip owner prefix
  | (($run.repo // "") | sub("^[^/]+/"; "")) as $repo_short
  | (.jobs // [])[]
  | . as $job
  | ($job.actions_info // [])[]
  | . as $au
  | (($au.sha // "") | ascii_downcase) as $sha_dc
  | (($au.action // "") | ascii_downcase) as $act_dc
  | ($sha_map[$sha_dc] // [])[]
  | select(.action == "" or .action == $act_dc)
  | {
      owner:                       ($run.owner // ""),
      repo:                        $repo_short,
      run_id:                      ($run.id // ""),
      run_attempt:                 ($run.run_attempt // 1 | tostring),
      run_url:                     ($run.html_url // ""),
      workflow_name:               ($run.name // ""),
      workflow_path:               ($run.path // ""),
      event:                       ($run.event // ""),
      head_branch:                 ($run.head_branch // ""),
      committer:                   ($run.committer // $run.workflow_run_actor_login // ""),
      run_started_at:              ($run.workflow_run_started_at // ""),
      run_conclusion:              ($run.conclusion // ""),
      job_id:                      ($job.id // "" | tostring),
      job_name:                    ($job.name // ""),
      job_url:                     ($job.html_url // ""),
      matched_action:              ($au.action // ""),
      matched_sha:                 ($au.sha // ""),
      matched_tag:                 ($au.tag // ""),
      action_executed_at:          ($au.timestamp // ""),
      is_imposter_commit:          ($au.is_imposter_commit // false),
      is_commit_on_default_branch: ($au.is_commit_on_default_branch // false),
      ioc_label:                   (.label // "")
    }
' > "$OUT" 2>/dev/null || true

# Drop empty file
[[ -s "$OUT" ]] || rm -f "$OUT"
HELPER_EOF
chmod +x "$TMPDIR_WORK/match_run.sh"

# Wrapper splits a tab-separated work line into the 3 leading args of
# match_run.sh so xargs -I {} can fan out without bash version-specific
# `wait -n` (which is unavailable on macOS bash 3.2).
cat > "$TMPDIR_WORK/match_run_wrapper.sh" << 'WRAPPER_EOF'
#!/usr/bin/env bash
IFS=$'\t' read -r OWNER REPO RUN_ID <<< "$1"
exec "$2" "$OWNER" "$REPO" "$RUN_ID" "$3" "$4" "$5" "$6"
WRAPPER_EOF
chmod +x "$TMPDIR_WORK/match_run_wrapper.sh"

# ── Process each org ───────────────────────────────────────────────

ALL_MATCHES="$TMPDIR_WORK/all_matches.jsonl"
: > "$ALL_MATCHES"

for CURRENT_ORG in "${ORGS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "Scanning org: ${CURRENT_ORG}"
  echo "════════════════════════════════════════════════════════════════"

  ORG_TMP="$TMPDIR_WORK/orgs/$(echo "$CURRENT_ORG" | sed 's/[^a-zA-Z0-9._-]/_/g')"
  mkdir -p "$ORG_TMP/matches"

  # ── Paginate through runs in window ─────────────────────────────
  RUNS_FILE="$ORG_TMP/runs.jsonl"
  : > "$RUNS_FILE"
  NEXT_TOKEN=""
  PAGE=0

  while :; do
    PAGE=$((PAGE+1))
    URL="${API_BASE}/github/${CURRENT_ORG}/actions/runs?start_time=${START_TIME}&end_time=${END_TIME}&limit=100"
    if [[ -n "$NEXT_TOKEN" ]]; then
      ENC=$(printf '%s' "$NEXT_TOKEN" | jq -sRr @uri)
      URL="${URL}&next_token=${ENC}"
    fi

    RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "$URL")
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    if [[ "$HTTP_CODE" -ne 200 ]]; then
      echo "  Warning: HTTP $HTTP_CODE on listing page $PAGE — skipping rest of org" >&2
      break
    fi

    PAGE_COUNT=$(echo "$BODY" | jq '(.workflow_runs // []) | length')
    if [[ "$PAGE_COUNT" -gt 0 ]]; then
      echo "$BODY" | jq -c '(.workflow_runs // [])[]' >> "$RUNS_FILE"
    fi
    NEXT_TOKEN=$(echo "$BODY" | jq -r '.next_token // ""')
    HAS_MORE=$(echo "$BODY" | jq -r '.has_more // false')

    CUM=$(wc -l < "$RUNS_FILE" | tr -d ' ')
    echo "  Page $PAGE: $PAGE_COUNT runs (cumulative: $CUM)"

    if [[ -z "$NEXT_TOKEN" || "$HAS_MORE" != "true" ]]; then break; fi
  done

  TOTAL_RUNS=$(wc -l < "$RUNS_FILE" | tr -d ' ')
  if [[ "$TOTAL_RUNS" -eq 0 ]]; then
    echo "  No runs in window."
    continue
  fi

  # Skip detail calls for runs the listing already says have 0 actions
  # (no actions_info to match → wasted call). This is purely an
  # optimization; it does not change result semantics.
  WORK="$ORG_TMP/work.tsv"
  jq -r --arg owner "$CURRENT_ORG" 'select((.action_count // 0) > 0)
    | [$owner, (.repo | sub("^[^/]+/"; "")), .id] | @tsv' "$RUNS_FILE" > "$WORK"

  TO_PROCESS=$(wc -l < "$WORK" | tr -d ' ')
  echo "  Total runs: $TOTAL_RUNS, runs with action data to scan: $TO_PROCESS"
  if [[ "$TO_PROCESS" -eq 0 ]]; then continue; fi

  # ── Fan out detail fetches in parallel ──────────────────────────
  echo "  Matching against $IOC_COUNT IOC(s) ($PARALLEL parallel)..."
  tr '\n' '\0' < "$WORK" | xargs -0 -P "$PARALLEL" -I {} \
    "$TMPDIR_WORK/match_run_wrapper.sh" {} \
    "$TMPDIR_WORK/match_run.sh" "$API_BASE" "$TOKEN" "$IOC_JSON" "$ORG_TMP/matches"

  # Collect matches
  shopt -s nullglob
  for f in "$ORG_TMP/matches"/*.jsonl; do
    cat "$f" >> "$ALL_MATCHES"
  done
  shopt -u nullglob

  ORG_MATCH_COUNT=$(grep -c . "$ALL_MATCHES" 2>/dev/null || echo 0)
  echo "  Cumulative matches: $ORG_MATCH_COUNT"
done

# ── Write CSV output ───────────────────────────────────────────────

CSV_HEADER="owner,repo,run_id,run_attempt,run_url,workflow_name,workflow_path,event,head_branch,committer,run_started_at,run_conclusion,job_id,job_name,job_url,matched_action,matched_sha,matched_tag,action_executed_at,is_imposter_commit,is_commit_on_default_branch,ioc_label"
echo "$CSV_HEADER" > "$OUTPUT"

TOTAL_MATCHES=0
if [[ -s "$ALL_MATCHES" ]]; then
  TOTAL_MATCHES=$(wc -l < "$ALL_MATCHES" | tr -d ' ')
fi

if [[ "$TOTAL_MATCHES" -gt 0 ]]; then
  jq -r '
    [.owner, .repo, .run_id, .run_attempt, .run_url, .workflow_name, .workflow_path,
     .event, .head_branch, .committer, .run_started_at, .run_conclusion,
     .job_id, .job_name, .job_url,
     .matched_action, .matched_sha, .matched_tag, .action_executed_at,
     (.is_imposter_commit | tostring), (.is_commit_on_default_branch | tostring),
     .ioc_label]
    | @csv
  ' "$ALL_MATCHES" >> "$OUTPUT"
fi

# ── Summary ────────────────────────────────────────────────────────

echo ""
echo "=== IOC MATCH SUMMARY for ${CONTEXT_INFO} ==="
echo "Window:           ${START_ISO} → ${END_ISO}"
echo "IOCs loaded:      $IOC_COUNT ($UNIQUE_SHAS unique SHAs)"
echo "Total matches:    $TOTAL_MATCHES"

if [[ "$TOTAL_MATCHES" -gt 0 ]]; then
  UNIQUE_RUNS=$(jq -s '[.[] | "\(.owner)/\(.repo)/\(.run_id)"] | unique | length' "$ALL_MATCHES")
  UNIQUE_REPOS=$(jq -s '[.[] | "\(.owner)/\(.repo)"] | unique | length' "$ALL_MATCHES")
  echo "Unique runs:      $UNIQUE_RUNS"
  echo "Unique repos:     $UNIQUE_REPOS"
  echo ""
  echo "Per-IOC breakdown:"
  jq -s -r '
    group_by(.ioc_label // "(no label)")
    | sort_by(-(. | length))
    | .[]
    | "  \(.[0].ioc_label // "(no label)"): \(length) match(es) across \(map("\(.owner)/\(.repo)") | unique | length) repo(s)"
  ' "$ALL_MATCHES"
fi

echo ""
echo "Output: $OUTPUT"
