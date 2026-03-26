#!/usr/bin/env bash
#
# list_workflow_actions.sh
#
# Lists GitHub Actions in use across a tenant's organizations with detailed
# information including security scores, repository lists, and outbound calls.
# Writes the results to a CSV file.
#
# Usage:
#   ./list_workflow_actions.sh --tenant <tenant> --token <stepsecurity-bearer-token> [--org <org>] [--output <file.csv>]
#
# Requirements: curl, jq, base64

set -euo pipefail

API_BASE="https://agent.api.stepsecurity.io/v1"
OUTPUT="workflow_actions_detailed.csv"
TENANT=""
TOKEN=""
ORG=""

usage() {
  echo "Usage: $0 --tenant <tenant> --token <stepsecurity-token> [--org <org>] [--output <file>]"
  echo ""
  echo "  --tenant       StepSecurity tenant identifier"
  echo "  --token        StepSecurity API bearer token"
  echo "  --org          GitHub organization name (default: all orgs)"
  echo "  --output       Output CSV file (default: workflow_actions_detailed.csv)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)     TENANT="$2"; shift 2 ;;
    --token)      TOKEN="$2"; shift 2 ;;
    --org)        ORG="$2"; shift 2 ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    *)            usage ;;
  esac
done

if [[ -z "$TENANT" || -z "$TOKEN" ]]; then
  usage
fi

# --- Check dependencies ---
for cmd in curl jq base64; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

# --- Helper: make authenticated GET call ---
api_get() {
  local url="$1"
  curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    "$url"
}

# --- Helper: make authenticated POST call ---
api_post() {
  local url="$1"
  local data="$2"
  local org="$3"
  curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "x-github-org: ${org}" \
    -d "$data" \
    "$url"
}

# --- Helper: CSV-escape a value ---
csv_escape() {
  local val="$1"
  if [[ "$val" == *","* || "$val" == *'"'* || "$val" == *$'\n'* ]]; then
    val="${val//\"/\"\"}"
    echo "\"${val}\""
  else
    echo "$val"
  fi
}

# --- Helper: fetch action details ---
get_action_details() {
  local action_name="$1"
  local owner="$2"

  local response
  response=$(api_post "${API_BASE}/github/actions/action-details" "{\"name\": \"${action_name}\"}" "$owner")
  local http_code
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -eq 200 ]; then
    echo "$body"
  else
    echo "{}"
  fi
}

# --- Helper: fetch repositories using a specific action ---
get_action_repositories() {
  local action_name="$1"
  local owner="$2"

  local encoded_action
  encoded_action=$(printf '%s' "$action_name" | base64)

  local response
  response=$(api_get "${API_BASE}/github/${owner}/actions/workflow-actions/${encoded_action}")
  local http_code
  http_code=$(echo "$response" | tail -n1)
  local body
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -eq 200 ]; then
    echo "$body" | jq -r '
      if type == "array" then
        [.[] | if type == "object" then (.repo // .repository // .name // empty) elif type == "string" then . else empty end]
      elif type == "object" then
        (
          (.repositories // .repos // .data // .result // null) as $arr
          | if $arr != null and ($arr | type) == "array" then
              [$arr[] | if type == "object" then (.repo // .repository // .name // empty) elif type == "string" then . else empty end]
            elif .repo != null then [.repo]
            else []
            end
        )
      else
        []
      end
      | unique
      | join(", ")
    ' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# --- Step 1: Determine organizations ---
if [[ -n "$ORG" ]]; then
  SELECTED_ORGS=("$ORG")
  CONTEXT_INFO="organization '${ORG}'"
else
  echo "Fetching organizations for tenant '${TENANT}'..."

  response=$(api_get "${API_BASE}/${TENANT}/github/organizations")
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne 200 ]; then
    echo "Error fetching organizations: HTTP ${http_code}"
    echo "$body"
    exit 1
  fi

  orgs=$(echo "$body" | jq -r '
    (if type == "object" then
      (.organizations // .result // .data // [])
    elif type == "array" then
      .
    else
      []
    end)
    | if type == "array" then
        .[] | if type == "string" then . elif type == "object" then (.organization // .name // empty) else empty end
      elif type == "object" then
        to_entries[].value | if type == "string" then . elif type == "object" then (.organization // .name // empty) else empty end
      else
        empty
      end
  ' 2>/dev/null)

  if [ -z "$orgs" ]; then
    echo "No organizations found for this tenant."
    exit 1
  fi

  SELECTED_ORGS=()
  while IFS= read -r line; do
    SELECTED_ORGS+=("$line")
  done <<< "$orgs"

  CONTEXT_INFO="all organizations (${#SELECTED_ORGS[@]} found)"
fi

echo "Querying workflow actions for ${CONTEXT_INFO}..."

# --- Step 2: Collect all actions across orgs ---
ALL_ACTIONS_JSON="[]"

for owner in "${SELECTED_ORGS[@]}"; do
  echo "  Fetching actions for '${owner}'..."

  response=$(api_get "${API_BASE}/github/${owner}/actions/workflow-actions")
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne 200 ]; then
    echo "  Warning: Error for ${owner}: HTTP ${http_code} - skipping."
    continue
  fi

  actions=$(echo "$body" | jq '
    if type == "object" then
      (.result // .data // .actions // .workflow_actions // .actions_in_use // [.])
    elif type == "array" then
      .
    else
      [.]
    end
    | if type == "array" then . else [.] end
  ' 2>/dev/null)

  count=$(echo "$actions" | jq 'length')

  if [ "$count" -eq 0 ]; then
    echo "  No actions found for '${owner}'."
    continue
  fi

  # Add owner to each action and normalize the name field
  actions_with_owner=$(echo "$actions" | jq --arg owner "$owner" '
    [.[] | if type == "object" then
      . + {"owner": $owner} |
      if .name == null and .action != null then . + {"name": .action} else . end
    else
      {"value": ., "owner": $owner}
    end]
  ')

  ALL_ACTIONS_JSON=$(echo "$ALL_ACTIONS_JSON" "$actions_with_owner" | jq -s '.[0] + .[1]')

  echo "  Found ${count} actions for '${owner}'."
done

TOTAL_ACTIONS=$(echo "$ALL_ACTIONS_JSON" | jq 'length')

if [ "$TOTAL_ACTIONS" -eq 0 ]; then
  echo "No workflow actions found for ${CONTEXT_INFO}."
  exit 0
fi

echo ""
echo "Found ${TOTAL_ACTIONS} actions. Fetching detailed information..."

# --- Step 3: Write CSV header ---
CSV_HEADER="owner,action_name,workflow_count,repo_count,repositories,labels,base_score,overall_score,popularity_score,maintained_score,security_policy_score,vulnerabilities_score,branch_protection_score,vulnerabilities_details,vulnerabilities_reason,security_policy_details,security_policy_reason,branch_protection_details,branch_protection_reason,maintained_reason,maintained_details,stargazers_count,license,action_type,description,repo_url,score_last_updated,popularity_usage,popularity_reason,maintained_action_name,outbound_endpoints"
echo "$CSV_HEADER" > "$OUTPUT"

# --- Step 4: For each action, fetch details + repos and write a CSV row ---
PROCESSED=0

echo "$ALL_ACTIONS_JSON" | jq -c '.[]' | while IFS= read -r action_json; do
  action_name=$(echo "$action_json" | jq -r '.name // .action // ""')
  owner=$(echo "$action_json" | jq -r '.owner // ""')
  workflow_count=$(echo "$action_json" | jq -r '(.count // .repo_count // 0)')
  labels=$(echo "$action_json" | jq -r '(.labels // []) | if type == "array" then join(", ") else tostring end')
  base_score=$(echo "$action_json" | jq -r '.score // ""')

  if [ -z "$action_name" ]; then
    continue
  fi

  PROCESSED=$((PROCESSED + 1))
  echo "  [${PROCESSED}/${TOTAL_ACTIONS}] Fetching details for ${action_name}..."

  # Fetch action details
  details=$(get_action_details "$action_name" "$owner")

  # Fetch repository list
  echo "      - Fetching repository list..."
  repositories=$(get_action_repositories "$action_name" "$owner")

  # Count unique repos
  if [ -n "$repositories" ]; then
    repo_count=$(echo "$repositories" | tr ',' '\n' | sed 's/^ *//' | grep -c '.')
  else
    repo_count=0
  fi

  # Extract score fields from details
  overall_score=$(echo "$details" | jq -r '.score.score // ""')
  score_last_updated=$(echo "$details" | jq -r '.score."score-last-updated" // ""')
  repo_url=$(echo "$details" | jq -r '.score.repoUrl // ""')
  license=$(echo "$details" | jq -r '.score.license // ""')
  stargazers_count=$(echo "$details" | jq -r '.score."stargazers-count" // ""')
  popularity_score=$(echo "$details" | jq -r '.score."popularity-score" // ""')
  popularity_usage=$(echo "$details" | jq -r '.score."popularity-usage" // ""')
  popularity_reason=$(echo "$details" | jq -r '.score."popularity-reason" // ""')
  branch_protection_score=$(echo "$details" | jq -r '.score."branch-protection-score" // ""')
  branch_protection_reason=$(echo "$details" | jq -r '.score."branch-protection-reason" // ""')
  branch_protection_details=$(echo "$details" | jq -r '.score."branch-protection-details" // "" | tostring')
  maintained_score=$(echo "$details" | jq -r '.score."maintained-score" // ""')
  maintained_reason=$(echo "$details" | jq -r '.score."maintained-reason" // ""')
  maintained_details=$(echo "$details" | jq -r '.score."maintained-details" // ""')
  security_policy_score=$(echo "$details" | jq -r '.score."security-policy-score" // ""')
  security_policy_reason=$(echo "$details" | jq -r '.score."security-policy-reason" // ""')
  security_policy_details=$(echo "$details" | jq -r '.score."security-policy-details" // "" | tostring')
  vulnerabilities_score=$(echo "$details" | jq -r '.score."vulnerabilities-score" // ""')
  vulnerabilities_reason=$(echo "$details" | jq -r '.score."vulnerabilities-reason" // ""')
  vulnerabilities_details=$(echo "$details" | jq -r '.score."vulnerabilities-details" // "" | tostring')

  # Extract other metadata
  action_type=$(echo "$details" | jq -r '.actionType // ""')
  description=$(echo "$details" | jq -r '.description // ""')
  maintained_action_name=$(echo "$details" | jq -r '.maintained_action_name // ""')

  # Extract outbound endpoints
  outbound_endpoints=$(echo "$details" | jq -r '
    [(.actionOutboundCallsFriendly // [])[] | (.["outbound-calls"] // [])[] |
      (.endpoint // "") as $ep | (.friendlyName // "") as $fn |
      if $ep != "" then
        if $fn != "" then "\($ep) (\($fn))" else $ep end
      else empty end
    ] | join(", ")
  ' 2>/dev/null || echo "")

  # Build CSV row using jq for proper escaping
  jq -n -r --arg owner "$owner" \
    --arg action_name "$action_name" \
    --arg workflow_count "$workflow_count" \
    --arg repo_count "$repo_count" \
    --arg repositories "$repositories" \
    --arg labels "$labels" \
    --arg base_score "$base_score" \
    --arg overall_score "$overall_score" \
    --arg popularity_score "$popularity_score" \
    --arg maintained_score "$maintained_score" \
    --arg security_policy_score "$security_policy_score" \
    --arg vulnerabilities_score "$vulnerabilities_score" \
    --arg branch_protection_score "$branch_protection_score" \
    --arg vulnerabilities_details "$vulnerabilities_details" \
    --arg vulnerabilities_reason "$vulnerabilities_reason" \
    --arg security_policy_details "$security_policy_details" \
    --arg security_policy_reason "$security_policy_reason" \
    --arg branch_protection_details "$branch_protection_details" \
    --arg branch_protection_reason "$branch_protection_reason" \
    --arg maintained_reason "$maintained_reason" \
    --arg maintained_details "$maintained_details" \
    --arg stargazers_count "$stargazers_count" \
    --arg license "$license" \
    --arg action_type "$action_type" \
    --arg description "$description" \
    --arg repo_url "$repo_url" \
    --arg score_last_updated "$score_last_updated" \
    --arg popularity_usage "$popularity_usage" \
    --arg popularity_reason "$popularity_reason" \
    --arg maintained_action_name "$maintained_action_name" \
    --arg outbound_endpoints "$outbound_endpoints" \
    '[$owner, $action_name, $workflow_count, $repo_count, $repositories, $labels, $base_score,
      $overall_score, $popularity_score, $maintained_score,
      $security_policy_score, $vulnerabilities_score, $branch_protection_score,
      $vulnerabilities_details, $vulnerabilities_reason,
      $security_policy_details, $security_policy_reason,
      $branch_protection_details, $branch_protection_reason,
      $maintained_reason, $maintained_details,
      $stargazers_count, $license, $action_type, $description,
      $repo_url, $score_last_updated,
      $popularity_usage, $popularity_reason,
      $maintained_action_name, $outbound_endpoints] | @csv' >> "$OUTPUT"
done

# --- Summary ---
num_rows=$(tail -n +2 "$OUTPUT" | wc -l | tr -d ' ')
echo ""
echo "Successfully processed ${num_rows} actions."
echo "Detailed results written to '${OUTPUT}'."
