#!/usr/bin/env bash
#
# control_compliance.sh
#
# Generates a CSV compliance report for ANY StepSecurity GitHub Actions
# control across one or more GitHub orgs (in a StepSecurity tenant).
#
# Works with any control name served by the
# /github/{owner}/{repo}/actions/controls/{control} API, e.g.:
#   JobsShouldUseSecureRegistry
#   GithubTokenShouldHaveMinPermission
#   OIDCShouldBeUsed
#   ActionsShouldBePinned
#   MaintainedGitHubActionsShouldBeUsed
#   DefaultBranchShouldBeProtected
#   GitHubHostedRunnerShouldBeHardened
#   SelfHostedRunnerShouldBeHardened
#
# Usage:
#   ./control_compliance.sh --control <name>[,<name>...] --tenant <tenant> --token <stepsecurity-bearer-token> [--org <org>] [--failed-only] [--include-details] [--output <file.csv>] [--parallel <n>]
#   ./control_compliance.sh --control <name>[,<name>...] --org <github-org> --token <stepsecurity-bearer-token> [--failed-only] [--include-details] [--output <file.csv>] [--parallel <n>]
#
# When --tenant is provided without --org, the report is generated for
# every org in the tenant. When --org is provided (with or without
# --tenant), the report is scoped to that single org.
#
# Requirements: curl, jq

set -euo pipefail

BASE_URL="https://agent.api.stepsecurity.io/v1"
OUTPUT="control_compliance_report.csv"
FAILED_ONLY=false
INCLUDE_DETAILS=false
PARALLEL=100
TENANT=""
ORG=""
TOKEN=""
CONTROLS_ARG=""

usage() {
  echo "Usage: $0 --control <name>[,<name>...] (--tenant <tenant> | --org <org>) --token <stepsecurity-token> [--org <org>] [--failed-only] [--include-details] [--output <file>] [--parallel <n>]"
  echo ""
  echo "  --control          Control name(s) to report on, comma-separated (e.g. JobsShouldUseSecureRegistry)"
  echo "  --tenant           StepSecurity tenant identifier (reports across all orgs in the tenant)"
  echo "  --org              GitHub organization name (scopes the report to a single org)"
  echo "  --token            StepSecurity API bearer token"
  echo "  --failed-only      Only include non-compliant entries (server-side status=Failed filter)"
  echo "  --include-details  Add an additional_info column with the control's structured detail as JSON"
  echo "  --output           Output CSV file (default: control_compliance_report.csv)"
  echo "  --parallel         Number of concurrent API requests (default: 100)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control)         CONTROLS_ARG="$2"; shift 2 ;;
    --tenant)          TENANT="$2"; shift 2 ;;
    --org)             ORG="$2"; shift 2 ;;
    --token)           TOKEN="$2"; shift 2 ;;
    --failed-only)     FAILED_ONLY=true; shift ;;
    --include-details) INCLUDE_DETAILS=true; shift ;;
    --output)          OUTPUT="$2"; shift 2 ;;
    --parallel)        PARALLEL="$2"; shift 2 ;;
    *)                 usage ;;
  esac
done

if [[ -z "$TOKEN" || -z "$CONTROLS_ARG" ]]; then
  usage
fi

if [[ -z "$TENANT" && -z "$ORG" ]]; then
  usage
fi

CONTROLS=()
IFS=',' read -ra CONTROLS <<< "$CONTROLS_ARG"
if [[ ${#CONTROLS[@]} -eq 0 ]]; then
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

# Fetching per repo (rather than org-wide) keeps every response well
# under the API's 6MB response limit, so no truncation applies no
# matter how many checks the org has in total.
cat > "$TMPDIR_WORK/fetch_control.sh" << 'HELPER_EOF'
#!/usr/bin/env bash
REPO="$1"
CONTROL="$2"
BASE_URL="$3"
ORG="$4"
TOKEN="$5"
OUTDIR="$6"
STATUS_FILTER="$7"

URL="${BASE_URL}/github/${ORG}/${REPO}/actions/controls/${CONTROL}"
if [[ -n "$STATUS_FILTER" ]]; then
  URL="${URL}?status=${STATUS_FILTER}"
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: $TOKEN" \
  "$URL" 2>/dev/null)

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

STATUS_FILTER=""
if [[ "$FAILED_ONLY" == "true" ]]; then
  STATUS_FILTER="Failed"
fi

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

  # Pass ?fields=repo so the response only carries Repo names (the only
  # field this script reads). Avoids loading workflows/topics/etc. for
  # every row, which keeps large orgs well under the API gateway
  # response limit.
  REPOS_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: $TOKEN" \
    "${BASE_URL}/github/${CURRENT_ORG}/actions/security-summary?fields=repo")

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
    CONTROL_DIR="$ORG_WORK/$(echo "$CONTROL" | sed 's/[^a-zA-Z0-9._-]/_/g')"
    mkdir -p "$CONTROL_DIR"

    echo ""
    echo "  Fetching ${CONTROL} across ${REPO_COUNT} repos (${PARALLEL} parallel)..."

    tr '\n' '\0' < "$ORG_WORK/repos.txt" | \
      xargs -0 -P "$PARALLEL" -I {} \
      "$TMPDIR_WORK/fetch_control.sh" {} "$CONTROL" "$BASE_URL" "$CURRENT_ORG" "$TOKEN" "$CONTROL_DIR" "$STATUS_FILTER"

    # Merge all per-repo JSON files for this control
    shopt -s nullglob
    REPO_FILES=("$CONTROL_DIR"/*.json)
    shopt -u nullglob

    if [[ ${#REPO_FILES[@]} -gt 0 ]]; then
      MERGED=$(jq -s 'add' "${REPO_FILES[@]}")
      ENTRY_COUNT=$(echo "$MERGED" | jq 'length')
      echo "    Found $ENTRY_COUNT check entries from ${#REPO_FILES[@]} repos"

      TRANSFORMED=$(echo "$MERGED" | jq --arg owner "$CURRENT_ORG" \
        --arg control "$CONTROL" \
        --argjson include_details "$INCLUDE_DETAILS" '
        [.[] | {
          owner: $owner,
          repo: (.repo // ""),
          workflow: (.workflow // ""),
          job: (.job // ""),
          control: $control,
          status: (.status // ""),
          reason: (.reason // ""),
          job_labels: ((.jobLabels // []) | join(", ")),
          workflow_url: (.workflowHTMLURL // ""),
          job_url: (.jobHTMLURL // ""),
          first_failed: (.firstFailedCheckTimeStamp // ""),
          last_failed: (.mostRecentFailedCheckTimeStamp // ""),
          last_checked: (.checkTimeStamp // ""),
          additional_info: (if $include_details and (.additionalInfo != null) then (.additionalInfo | tojson) else "" end)
        }]
      ')

      ALL_MERGED=$(jq -s '.[0] + .[1]' "$ALL_CHECKS" <(echo "$TRANSFORMED"))
      echo "$ALL_MERGED" > "$ALL_CHECKS"
    else
      echo "    Found 0 check entries"
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

HEADER="owner,repo,workflow,job,control,status,reason,job_labels,workflow_url,job_url,first_failed,last_failed,last_checked"
if [[ "$INCLUDE_DETAILS" == "true" ]]; then
  HEADER="${HEADER},additional_info"
fi
echo "$HEADER" > "$OUTPUT"

jq -r --argjson include_details "$INCLUDE_DETAILS" '
  sort_by(.owner, .repo, .control, .workflow, .job)[]
  | [.owner, .repo, .workflow, .job, .control, .status, .reason, .job_labels, .workflow_url, .job_url, .first_failed, .last_failed, .last_checked]
    + (if $include_details then [.additional_info] else [] end)
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
echo "Controls:          ${CONTROLS[*]}"
echo "Total orgs:        $(echo "$SUMMARY" | jq '.orgs')"
echo "Total repos:       $(echo "$SUMMARY" | jq '.repos')"
echo "Total checks:      $(echo "$SUMMARY" | jq '.total')"
echo "  Passed:          $(echo "$SUMMARY" | jq '.passed')"
echo "  Failed:          $(echo "$SUMMARY" | jq '.failed')"
echo "  Suppressed:      $(echo "$SUMMARY" | jq '.suppressed')"

# Per-control breakdown
echo ""
echo "Per-control breakdown:"
jq -r '
  group_by(.control)
  | sort_by(.[0].control)
  | .[]
  | "  \(.[0].control): total=\(length), passed=\([.[] | select(.status == "Passed")] | length), failed=\([.[] | select(.status == "Failed")] | length), suppressed=\([.[] | select(.status == "Suppressed")] | length)"
' "$ALL_CHECKS"

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
  | "  \(.[0].owner)/\(.[0].repo): \(length) failing check(s)"
' "$ALL_CHECKS")

if [[ -n "$FAILED_REPOS" ]]; then
  FAILED_REPO_COUNT=$(jq '[.[] | select(.status == "Failed") | "\(.owner)/\(.repo)"] | unique | length' "$ALL_CHECKS")
  echo ""
  echo "Repos with non-compliant checks ($FAILED_REPO_COUNT):"
  echo "$FAILED_REPOS"
fi
