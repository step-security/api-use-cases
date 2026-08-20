#!/usr/bin/env bash
#
# detect_deleted_workflow_runs.sh
#
# Snapshots workflow-run metadata from the StepSecurity API and compares it
# against the GitHub Actions API to find runs that no longer exist on GitHub.
#
# Why this matters: StepSecurity retains run metadata independently of GitHub.
# Deleting a workflow run in GitHub Actions is a common way to remove evidence
# after a secret-exfiltration attempt, and GitHub keeps no tenant-visible record
# of the deletion. Any run that StepSecurity recorded but GitHub now returns 404
# for is a lead worth investigating.
#
# Usage:
#   ./detect_deleted_workflow_runs.sh --owner <org> --repo <repo> \
#       --token <stepsecurity-token> --github-token <github-token> \
#       [--start-time <unix|YYYY-MM-DD>] [--end-time <unix|YYYY-MM-DD>] \
#       [--min-run-id <id>] [--max-run-id <id>] \
#       [--output-dir <dir>] [--parallel <n>] [--page-size <n>] [--skip-github-check]
#
# Scope: pass a time range, a run-id range, or both. A run-id range alone still
# needs a fetch window, so the default 90-day window is used and runs outside the
# id range are filtered out client-side (the API does not filter by run id).
#
# Requirements: curl, jq
#
# The GitHub token needs `actions: read` on the target repo (a fine-grained PAT
# with Actions:Read, or a classic PAT with `repo` for private repositories). It
# is optional for public repos, which can be read anonymously, but anonymous
# access only gets 60 API requests/hour and this spends one per run.

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1/github"
GITHUB_API="https://api.github.com"

# The runs listing rejects a start_time more than 90 days in the past. The check
# is re-evaluated against the server clock on every request, so a start_time
# sitting exactly on the 90-day edge passes the first page and then 400s a few
# seconds later mid-pagination. Keep a margin inside the limit.
MAX_LOOKBACK_DAYS=90
LOOKBACK_MARGIN_SECONDS=3600

OWNER=""
REPO=""
TOKEN=""
GITHUB_TOKEN=""
START_TIME=""
END_TIME=""
MIN_RUN_ID=""
MAX_RUN_ID=""
OUTPUT_DIR="deleted-run-analysis"
PARALLEL=20
PAGE_SIZE=100
SKIP_GITHUB_CHECK=false

usage() {
  cat <<'EOF'
Usage: detect_deleted_workflow_runs.sh --owner <org> --repo <repo> --token <stepsecurity-token> [options]

Required:
  --owner               GitHub organization / owner name
  --repo                Repository name
  --token               StepSecurity API token

Optional (strongly recommended):
  --github-token        GitHub token with `actions: read` on the target repo.
                        Omit it for a public repo to check anonymously, but note
                        anonymous access is capped at 60 API requests/hour versus
                        5,000 authenticated, and this uses one request per run.

Scope (pass a time range, a run-id range, or both):
  --start-time          Window start: Unix epoch seconds or YYYY-MM-DD (default: 90 days ago)
  --end-time            Window end:   Unix epoch seconds or YYYY-MM-DD (default: now)
  --min-run-id          Only keep runs with id >= this value
  --max-run-id          Only keep runs with id <= this value

Options:
  --output-dir          Directory for JSON output (default: deleted-run-analysis)
  --parallel            Concurrent GitHub existence checks (default: 20)
  --page-size           StepSecurity page size (default: 100)
  --skip-github-check   Only snapshot StepSecurity metadata, skip the GitHub diff
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)              OWNER="$2"; shift 2 ;;
    --repo)               REPO="$2"; shift 2 ;;
    --token)              TOKEN="$2"; shift 2 ;;
    --github-token)       GITHUB_TOKEN="$2"; shift 2 ;;
    --start-time)         START_TIME="$2"; shift 2 ;;
    --end-time)           END_TIME="$2"; shift 2 ;;
    --min-run-id)         MIN_RUN_ID="$2"; shift 2 ;;
    --max-run-id)         MAX_RUN_ID="$2"; shift 2 ;;
    --output-dir)         OUTPUT_DIR="$2"; shift 2 ;;
    --parallel)           PARALLEL="$2"; shift 2 ;;
    --page-size)          PAGE_SIZE="$2"; shift 2 ;;
    --skip-github-check)  SKIP_GITHUB_CHECK=true; shift ;;
    -h|--help)            usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool is required" >&2; exit 1; }
done

[[ -z "$OWNER" || -z "$REPO" || -z "$TOKEN" ]] && usage

# --github-token is optional. Public repos can be checked unauthenticated, and
# the preflight below proves whether that actually works for this repo. The only
# real cost of going unauthenticated is a much smaller rate-limit budget, which
# the preflight also checks against the number of runs in scope.
GH_AUTH_ARGS=()
if [[ -n "$GITHUB_TOKEN" ]]; then
  GH_AUTH_ARGS=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

# Accept either a Unix timestamp or YYYY-MM-DD. GNU date and BSD (macOS) date
# take different flags, so try both.
to_epoch() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"; return 0
  fi
  date -u -d "$value" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%d" "$value" +%s 2>/dev/null && return 0
  echo "Error: could not parse date '$value' (use Unix seconds or YYYY-MM-DD)" >&2
  exit 1
}

NOW=$(date -u +%s)
EARLIEST=$(( NOW - MAX_LOOKBACK_DAYS * 86400 + LOOKBACK_MARGIN_SECONDS ))

if [[ -n "$START_TIME" ]]; then
  START_EPOCH=$(to_epoch "$START_TIME")
else
  START_EPOCH="$EARLIEST"
fi
if [[ -n "$END_TIME" ]]; then
  END_EPOCH=$(to_epoch "$END_TIME")
else
  END_EPOCH="$NOW"
fi

if (( END_EPOCH < START_EPOCH )); then
  echo "Error: --end-time must not be earlier than --start-time" >&2
  exit 1
fi
if (( NOW - START_EPOCH > MAX_LOOKBACK_DAYS * 86400 )); then
  echo "Error: --start-time cannot be more than ${MAX_LOOKBACK_DAYS} days in the past (API limit)" >&2
  exit 1
fi
# Nudge a start_time that is inside the limit but too close to its edge to
# survive pagination, rather than failing partway through.
if (( START_EPOCH < EARLIEST )); then
  echo "Note: --start-time is within ${LOOKBACK_MARGIN_SECONDS}s of the ${MAX_LOOKBACK_DAYS}-day API limit; clamping it forward to stay inside the window."
  START_EPOCH="$EARLIEST"
fi

mkdir -p "$OUTPUT_DIR"
ALL_RUNS="$OUTPUT_DIR/workflow-runs.json"
DELETED_RUNS="$OUTPUT_DIR/deleted-runs.json"
SUMMARY="$OUTPUT_DIR/summary.json"
PAGES_RAW="$OUTPUT_DIR/.pages.jsonl"
: > "$PAGES_RAW"

echo "Repository:  $OWNER/$REPO"
echo "Window:      $(date -u -r "$START_EPOCH" 2>/dev/null || date -u -d "@$START_EPOCH") .. $(date -u -r "$END_EPOCH" 2>/dev/null || date -u -d "@$END_EPOCH")"
[[ -n "$MIN_RUN_ID" ]] && echo "Min run id:  $MIN_RUN_ID"
[[ -n "$MAX_RUN_ID" ]] && echo "Max run id:  $MAX_RUN_ID"
echo "----------------------------------------"

# ---------------------------------------------------------------------------
# Step 1: page through the StepSecurity runs listing.
# ---------------------------------------------------------------------------
NEXT_TOKEN=""
PAGE=0
while :; do
  PAGE=$((PAGE + 1))
  URL="$BASE_URL/$OWNER/$REPO/actions/runs?limit=$PAGE_SIZE&start_time=$START_EPOCH&end_time=$END_EPOCH"
  if [[ -n "$NEXT_TOKEN" ]]; then
    URL="$URL&next_token=$(jq -rn --arg t "$NEXT_TOKEN" '$t|@uri')"
  fi

  HTTP_BODY=$(mktemp)
  HTTP_CODE=$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' -X GET "$URL" \
    -H 'accept: application/json' \
    -H "Authorization: $TOKEN")

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Error: StepSecurity API returned HTTP $HTTP_CODE" >&2
    head -c 400 "$HTTP_BODY" >&2; echo >&2
    rm -f "$HTTP_BODY"
    exit 1
  fi

  if ! jq -e . "$HTTP_BODY" >/dev/null 2>&1; then
    echo "Error: StepSecurity API returned a non-JSON response" >&2
    rm -f "$HTTP_BODY"
    exit 1
  fi

  COUNT=$(jq '(.workflow_runs // []) | length' "$HTTP_BODY")
  jq -c '(.workflow_runs // [])[]' "$HTTP_BODY" >> "$PAGES_RAW"
  echo "  page $PAGE: $COUNT runs"

  NEXT_TOKEN=$(jq -r '.next_token // ""' "$HTTP_BODY")
  rm -f "$HTTP_BODY"
  [[ -z "$NEXT_TOKEN" ]] && break
done

# Normalize to the metadata we care about, apply the run-id range, dedupe by id.
jq -s \
  --arg min "${MIN_RUN_ID:-}" \
  --arg max "${MAX_RUN_ID:-}" \
  --arg owner "$OWNER" \
  --arg repo "$REPO" '
  map({
    run_id:        (.id // "" | tostring),
    run_number:    .run_number,
    name:          .name,
    workflow_path: .path,
    head_branch:   .head_branch,
    event:         .event,
    conclusion:    .conclusion,
    actor:         (.workflow_run_actor_login // .committer),
    committer:     .committer,
    start_time_utc: .start_time_utc,
    started_at:    (if (.start_time_utc // 0) > 0
                    then (.start_time_utc | todate)
                    else null end),
    duration_seconds:        .execution_duration_in_seconds,
    is_harden_runner_enabled: (.is_harden_runner_enabled // false),
    job_count:               (.job_count // 0),
    secrets_detected_count:  (.secrets_detected_count // 0),
    new_endpoints_count:     (.new_endpoints_count // 0),
    files_overwritten_count: (.files_overwritten_count // 0),
    imposter_commits_count:  (.imposter_commits_count // 0),
    suspicious_process_count: (.suspicious_process_count // 0),
    stepsecurity_url: "https://app.stepsecurity.io/github/\($owner)/\($repo)/actions/runs/\(.id)",
    github_url:       "https://github.com/\($owner)/\($repo)/actions/runs/\(.id)"
  })
  | map(select(.run_id != ""))
  | (if $min == "" then . else map(select((.run_id|tonumber) >= ($min|tonumber))) end)
  | (if $max == "" then . else map(select((.run_id|tonumber) <= ($max|tonumber))) end)
  | unique_by(.run_id)
  | sort_by(.run_id | tonumber)
' "$PAGES_RAW" > "$ALL_RUNS"
rm -f "$PAGES_RAW"

TOTAL=$(jq 'length' "$ALL_RUNS")
echo "----------------------------------------"
echo "StepSecurity runs in scope: $TOTAL"
echo "Metadata written to: $ALL_RUNS"

# Every exit path writes the same summary keys so consumers never have to guess
# which shape they got. github_checked distinguishes "0 deleted" from "not looked".
write_summary() {
  jq -n \
    --arg owner "$OWNER" --arg repo "$REPO" \
    --argjson start "$START_EPOCH" --argjson end "$END_EPOCH" \
    --argjson total "${1:-0}" --argjson checked "${2:-0}" \
    --argjson present "${3:-0}" --argjson deleted "${4:-0}" \
    --argjson inaccessible "${5:-0}" --argjson rate_limited "${6:-0}" \
    --argjson unknown "${7:-0}" \
    --argjson github_checked "${8:-false}" \
    --arg note "${9:-}" \
    '{owner:$owner, repo:$repo,
      window: {start_utc: ($start|todate), end_utc: ($end|todate)},
      stepsecurity_runs:$total, github_checked:$github_checked, checked:$checked,
      present_on_github:$present, deleted_from_github:$deleted,
      inaccessible:$inaccessible, rate_limited:$rate_limited, unknown:$unknown}
     + (if $note == "" then {} else {note:$note} end)' > "$SUMMARY"
}

if [[ "$TOTAL" -eq 0 ]]; then
  write_summary 0 0 0 0 0 0 0 false \
    "No runs returned for this scope. Widen the window or check the StepSecurity token."
  exit 0
fi

if [[ "$SKIP_GITHUB_CHECK" == "true" ]]; then
  echo "Skipping GitHub existence check (--skip-github-check)."
  write_summary "$TOTAL" 0 0 0 0 0 0 false "GitHub diff skipped"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2 preflight: prove the GitHub token can actually see this repo's runs.
#
# This matters more than it looks. For a PRIVATE repo, GitHub returns 404 (not
# 403) for a token that lacks `actions: read`, so as not to leak existence. An
# underscoped token would therefore make every single run look "deleted". Verify
# read access up front and refuse to guess.
# ---------------------------------------------------------------------------
echo "----------------------------------------"
if [[ -n "$GITHUB_TOKEN" ]]; then
  echo "Verifying GitHub token access to $OWNER/$REPO"
else
  echo "Verifying unauthenticated GitHub access to $OWNER/$REPO (no --github-token given)"
fi

gh_status() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    "${GH_AUTH_ARGS[@]+"${GH_AUTH_ARGS[@]}"}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$1" 2>/dev/null || echo "000"
}

access_hint() {
  if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "       The token needs 'actions: read' on $OWNER/$REPO." >&2
  else
    echo "       This repo is not readable anonymously, so pass --github-token with" >&2
    echo "       'actions: read' on $OWNER/$REPO." >&2
  fi
}

REPO_CODE=$(gh_status "$GITHUB_API/repos/$OWNER/$REPO")
if [[ "$REPO_CODE" != "200" ]]; then
  echo "Error: GitHub returned HTTP $REPO_CODE for repos/$OWNER/$REPO." >&2
  echo "       Without read access a 404 on an individual run is indistinguishable" >&2
  echo "       from a deletion, so this would report every run as deleted." >&2
  access_hint
  exit 1
fi

RUNS_CODE=$(gh_status "$GITHUB_API/repos/$OWNER/$REPO/actions/runs?per_page=1")
if [[ "$RUNS_CODE" != "200" ]]; then
  echo "Error: GitHub returned HTTP $RUNS_CODE for the Actions runs listing." >&2
  echo "       Without it every run lookup 404s and would be misreported as deleted." >&2
  access_hint
  exit 1
fi
echo "  repo readable, Actions runs listing readable"

# Rate-limit budget. This is the practical blocker for the unauthenticated path:
# anonymous GitHub API calls get 60/hour, versus 5,000/hour authenticated, and
# this scenario spends one request per run. Check the real remaining quota rather
# than assuming, and stop before burning it on a partial answer.
RATE_JSON=$(curl -sS -H 'Accept: application/vnd.github+json' \
  "${GH_AUTH_ARGS[@]+"${GH_AUTH_ARGS[@]}"}" \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$GITHUB_API/rate_limit" 2>/dev/null || echo '{}')
REMAINING=$(printf '%s' "$RATE_JSON" | jq -r '.resources.core.remaining // .rate.remaining // empty')
RESET_AT=$(printf '%s' "$RATE_JSON" | jq -r '.resources.core.reset // .rate.reset // empty')

if [[ -n "$REMAINING" ]]; then
  echo "  GitHub API requests remaining: $REMAINING (need $TOTAL)"
  if (( REMAINING < TOTAL )); then
    echo "" >&2
    echo "Error: not enough GitHub API quota to check every run ($REMAINING remaining, $TOTAL needed)." >&2
    if [[ -n "$RESET_AT" ]]; then
      echo "       Quota resets at $(date -u -r "$RESET_AT" 2>/dev/null || date -u -d "@$RESET_AT")." >&2
    fi
    if [[ -z "$GITHUB_TOKEN" ]]; then
      echo "       Anonymous access is capped at 60 requests/hour. Pass --github-token" >&2
      echo "       for a 5,000/hour budget." >&2
    else
      echo "       Narrow the scope with --start-time/--end-time or a run-id range," >&2
      echo "       or wait for the reset." >&2
    fi
    echo "       Stopping rather than reporting a partial result as if it were complete." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: ask GitHub whether each run still exists.
#   200 => present
#   404 => deleted (access already proven above)
#   401/403/429 => cannot tell; reported separately, never as "deleted"
# ---------------------------------------------------------------------------
echo "----------------------------------------"
echo "Checking $TOTAL runs against the GitHub Actions API (parallel: $PARALLEL)"

STATUS_DIR=$(mktemp -d)
check_run() {
  local run_id="$1"
  local code
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    "${auth[@]+"${auth[@]}"}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$GITHUB_API/repos/$OWNER/$REPO/actions/runs/$run_id" 2>/dev/null || echo "000")
  echo "$code" > "$STATUS_DIR/$run_id"
}
export -f check_run
export GITHUB_TOKEN GITHUB_API OWNER REPO STATUS_DIR

# xargs -P gives portable bounded concurrency without requiring GNU parallel.
jq -r '.[].run_id' "$ALL_RUNS" \
  | xargs -P "$PARALLEL" -I {} bash -c 'check_run "$@"' _ {}

# Fold the per-run status codes back into the metadata.
STATUS_JSON=$(mktemp)
{
  echo "{"
  first=true
  for f in "$STATUS_DIR"/*; do
    [[ -e "$f" ]] || continue
    rid=$(basename "$f")
    code=$(cat "$f")
    if [[ "$first" == true ]]; then first=false; else echo ","; fi
    printf '"%s": "%s"' "$rid" "$code"
  done
  echo "}"
} > "$STATUS_JSON"
rm -rf "$STATUS_DIR"

jq -s '
  .[0] as $runs | .[1] as $status |
  $runs | map(. + {github_http_status: ($status[.run_id] // "000")})
  | map(. + {github_state:
      (if   .github_http_status == "200" then "present"
       elif .github_http_status == "404" then "deleted"
       elif .github_http_status == "403" or .github_http_status == "401" then "inaccessible"
       elif .github_http_status == "429" then "rate_limited"
       else "unknown" end)})
' "$ALL_RUNS" "$STATUS_JSON" > "$ALL_RUNS.tmp"
mv "$ALL_RUNS.tmp" "$ALL_RUNS"
rm -f "$STATUS_JSON"

jq '[ .[] | select(.github_state == "deleted") ]' "$ALL_RUNS" > "$DELETED_RUNS"

DELETED=$(jq 'length' "$DELETED_RUNS")
PRESENT=$(jq '[.[] | select(.github_state == "present")] | length' "$ALL_RUNS")
INACCESSIBLE=$(jq '[.[] | select(.github_state == "inaccessible")] | length' "$ALL_RUNS")
RATE_LIMITED=$(jq '[.[] | select(.github_state == "rate_limited")] | length' "$ALL_RUNS")
UNKNOWN=$(jq '[.[] | select(.github_state == "unknown")] | length' "$ALL_RUNS")

write_summary "$TOTAL" "$TOTAL" "$PRESENT" "$DELETED" \
  "$INACCESSIBLE" "$RATE_LIMITED" "$UNKNOWN" true ""

echo "----------------------------------------"
echo "Present on GitHub:     $PRESENT"
echo "DELETED from GitHub:   $DELETED"
echo "Inaccessible (401/403): $INACCESSIBLE"
echo "Rate limited (429):     $RATE_LIMITED"
echo "Unknown:                $UNKNOWN"
echo "----------------------------------------"

if (( RATE_LIMITED > 0 || UNKNOWN > 0 )); then
  echo "WARNING: some runs could not be confirmed. Re-run with a lower --parallel"
  echo "         before treating the deleted count as final."
fi
if (( INACCESSIBLE > 0 )); then
  echo "WARNING: $INACCESSIBLE runs returned 401/403. The GitHub token likely lacks"
  echo "         'actions: read' on this repo. These are NOT counted as deleted."
fi

# A handful of deleted runs is a real signal. Everything deleted is almost always
# a token/repo problem, or a retention policy that aged out the whole window.
# Say so rather than reporting a five-figure "attack".
if (( DELETED == TOTAL && TOTAL > 5 )); then
  echo ""
  echo "WARNING: every run in scope came back 404. Preflight proved the token can read"
  echo "         this repo, so before treating this as mass deletion check whether the"
  echo "         window predates the repo's Actions retention period, or whether the"
  echo "         runs belong to a different repo than the one queried."
fi

if (( DELETED > 0 )); then
  echo ""
  echo "Deleted runs (investigate these first):"
  jq -r '.[] | "  run \(.run_id)  \(.workflow_path // "?")  branch=\(.head_branch // "?")  actor=\(.actor // "?")  started=\(.started_at // "?")"' "$DELETED_RUNS"
  echo ""
  echo "Full details: $DELETED_RUNS"
else
  echo ""
  echo "No deleted runs found in this scope."
  echo "Next step: no run was removed, so review workflow files for bulk secret"
  echo "exposure instead - search the repo (all branches) for 'toJSON(secrets)'"
  echo "and for dynamic indexing like 'secrets[<expression>]'."
fi

echo ""
echo "Outputs:"
echo "  $ALL_RUNS"
echo "  $DELETED_RUNS"
echo "  $SUMMARY"
