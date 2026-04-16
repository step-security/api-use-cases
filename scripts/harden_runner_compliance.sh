#!/usr/bin/env bash
#
# harden_runner_compliance.sh
#
# Generates a CSV compliance report showing which workflow jobs
# across a GitHub org are missing harden-runner.
#
# Usage:
#   ./harden_runner_compliance.sh --org <github-org> --token <stepsecurity-bearer-token> [--failed-only] [--output <file.csv>] [--parallel <n>]
#
# Requirements: curl, jq

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1"
CONTROLS=("GitHubHostedRunnerShouldBeHardened" "SelfHostedRunnerShouldBeHardened")
OUTPUT="harden_runner_report.csv"
FAILED_ONLY=false
PARALLEL=100
ORG=""
TOKEN=""

usage() {
  echo "Usage: $0 --org <org> --token <stepsecurity-token> [--failed-only] [--output <file>] [--parallel <n>]"
  echo ""
  echo "  --org          GitHub organization name"
  echo "  --token        StepSecurity API bearer token"
  echo "  --failed-only  Only include non-compliant jobs"
  echo "  --output       Output CSV file (default: harden_runner_report.csv)"
  echo "  --parallel     Number of concurrent API requests (default: 100)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)        ORG="$2"; shift 2 ;;
    --token)      TOKEN="$2"; shift 2 ;;
    --failed-only) FAILED_ONLY=true; shift ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --parallel)   PARALLEL="$2"; shift 2 ;;
    *)            usage ;;
  esac
done

if [[ -z "$ORG" || -z "$TOKEN" ]]; then
  usage
fi

# ── 1. Set up working directory ────────────────────────────────────

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

ALL_CHECKS="$TMPDIR_WORK/all_checks.json"
echo "[]" > "$ALL_CHECKS"

# ── 2. Fetch repository list ──────────────────────────────────────

echo "Fetching repository list for '${ORG}'..."

REPOS_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: $TOKEN" \
  "${BASE_URL}/github/${ORG}/actions/security-summary")

HTTP_CODE=$(echo "$REPOS_RESPONSE" | tail -1)
REPOS_BODY=$(echo "$REPOS_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ne 200 ]]; then
  echo "Error: HTTP $HTTP_CODE fetching repository list" >&2
  exit 1
fi

echo "$REPOS_BODY" | jq -r '.[].Repo | select(. != "#all#")' > "$TMPDIR_WORK/repos.txt"
REPO_COUNT=$(wc -l < "$TMPDIR_WORK/repos.txt" | tr -d ' ')
echo "Found $REPO_COUNT repositories"

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

# ── 4. Fetch control data per repo in parallel ────────────────────

for CONTROL in "${CONTROLS[@]}"; do
  if [[ "$CONTROL" == "SelfHostedRunnerShouldBeHardened" ]]; then
    RUNNER_TYPE="Self-Hosted"
  else
    RUNNER_TYPE="GitHub-Hosted"
  fi

  CONTROL_DIR="$TMPDIR_WORK/$CONTROL"
  mkdir -p "$CONTROL_DIR"

  echo ""
  echo "Fetching ${CONTROL} across ${REPO_COUNT} repos (${PARALLEL} parallel)..."

  tr '\n' '\0' < "$TMPDIR_WORK/repos.txt" | \
    xargs -0 -P "$PARALLEL" -I {} \
    "$TMPDIR_WORK/fetch_control.sh" {} "$CONTROL" "$BASE_URL" "$ORG" "$TOKEN" "$CONTROL_DIR"

  # Merge all per-repo JSON files for this control
  shopt -s nullglob
  REPO_FILES=("$CONTROL_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#REPO_FILES[@]} -gt 0 ]]; then
    MERGED=$(jq -s 'add' "${REPO_FILES[@]}")
    ENTRY_COUNT=$(echo "$MERGED" | jq 'length')
    echo "  Found $ENTRY_COUNT job entries from ${#REPO_FILES[@]} repos"

    TRANSFORMED=$(echo "$MERGED" | jq --arg control "$CONTROL" \
      --arg runner_type "$RUNNER_TYPE" \
      --argjson failed_only "$FAILED_ONLY" '
      [.[] | {
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
    echo "  Found 0 job entries"
  fi
done

# ── 5. Sort and write CSV ────────────────────────────────────────────

TOTAL=$(jq 'length' "$ALL_CHECKS")

if [[ "$TOTAL" -eq 0 ]]; then
  echo ""
  echo "No results found."
  exit 0
fi

# Sort by repo, workflow, job and write CSV
echo "repo,workflow,job,control,runner_type,status,job_labels,workflow_url,job_url,first_failed,last_failed,last_checked" > "$OUTPUT"

jq -r '
  sort_by(.repo, .workflow, .job)[]
  | [.repo, .workflow, .job, .control, .runner_type, .status, .job_labels, .workflow_url, .job_url, .first_failed, .last_failed, .last_checked]
  | @csv
' "$ALL_CHECKS" >> "$OUTPUT"

echo ""
echo "Wrote $TOTAL entries to $OUTPUT"

# ── 6. Summary ───────────────────────────────────────────────────────

SUMMARY=$(jq '
  {
    total:      length,
    repos:      ([.[].repo] | unique | length),
    passed:     ([.[] | select(.status == "Passed")] | length),
    failed:     ([.[] | select(.status == "Failed")] | length),
    suppressed: ([.[] | select(.status == "Suppressed")] | length)
  }
' "$ALL_CHECKS")

echo ""
echo "=== COMPLIANCE SUMMARY for '${ORG}' ==="
echo "Total repos:       $(echo "$SUMMARY" | jq '.repos')"
echo "Total job checks:  $(echo "$SUMMARY" | jq '.total')"
echo "  Passed:          $(echo "$SUMMARY" | jq '.passed')"
echo "  Failed:          $(echo "$SUMMARY" | jq '.failed')"
echo "  Suppressed:      $(echo "$SUMMARY" | jq '.suppressed')"

# List repos with failures
FAILED_REPOS=$(jq -r '
  [.[] | select(.status == "Failed")]
  | group_by(.repo)
  | sort_by(.[0].repo)
  | .[]
  | "  \(.[0].repo): \(length) failing job(s)"
' "$ALL_CHECKS")

if [[ -n "$FAILED_REPOS" ]]; then
  FAILED_REPO_COUNT=$(jq '[.[] | select(.status == "Failed") | .repo] | unique | length' "$ALL_CHECKS")
  echo ""
  echo "Repos with non-compliant jobs ($FAILED_REPO_COUNT):"
  echo "$FAILED_REPOS"
fi
