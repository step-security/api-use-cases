#!/usr/bin/env bash
#
# harden_runner_compliance.sh
#
# Generates a CSV compliance report showing which workflow jobs
# across a GitHub org are missing harden-runner.
#
# Usage:
#   ./harden_runner_compliance.sh --org <github-org> --token <stepsecurity-bearer-token> [--failed-only] [--output <file.csv>]
#
# Requirements: curl, jq

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1"
CONTROLS=("GitHubHostedRunnerShouldBeHardened" "SelfHostedRunnerShouldBeHardened")
OUTPUT="harden_runner_report.csv"
FAILED_ONLY=false
ORG=""
TOKEN=""

usage() {
  echo "Usage: $0 --org <org> --token <stepsecurity-token> [--failed-only] [--output <file>]"
  echo ""
  echo "  --org          GitHub organization name"
  echo "  --token        StepSecurity API bearer token"
  echo "  --failed-only  Only include non-compliant jobs"
  echo "  --output       Output CSV file (default: harden_runner_report.csv)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)        ORG="$2"; shift 2 ;;
    --token)      TOKEN="$2"; shift 2 ;;
    --failed-only) FAILED_ONLY=true; shift ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    *)            usage ;;
  esac
done

if [[ -z "$ORG" || -z "$TOKEN" ]]; then
  usage
fi

# ── 1. Fetch control data from StepSecurity API ─────────────────────

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

ALL_CHECKS="$TMPDIR_WORK/all_checks.json"
echo "[]" > "$ALL_CHECKS"

for CONTROL in "${CONTROLS[@]}"; do
  if [[ "$CONTROL" == "SelfHostedRunnerShouldBeHardened" ]]; then
    RUNNER_TYPE="Self-Hosted"
  else
    RUNNER_TYPE="GitHub-Hosted"
  fi

  echo "Fetching ${CONTROL} for org '${ORG}'..."

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: $TOKEN" \
    "${BASE_URL}/github/${ORG}/%5Ball%5D/actions/controls/${CONTROL}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "  Error: HTTP $HTTP_CODE fetching $CONTROL" >&2
    continue
  fi

  ENTRY_COUNT=$(echo "$BODY" | jq 'length')
  echo "  Found $ENTRY_COUNT job entries"

  TRANSFORMED=$(echo "$BODY" | jq --arg control "$CONTROL" \
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

  # Merge into all_checks
  MERGED=$(jq -s '.[0] + .[1]' "$ALL_CHECKS" <(echo "$TRANSFORMED"))
  echo "$MERGED" > "$ALL_CHECKS"
done

# ── 2. Sort and write CSV ────────────────────────────────────────────

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

# ── 3. Summary ───────────────────────────────────────────────────────

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
