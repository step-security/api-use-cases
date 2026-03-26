#!/usr/bin/env bash
#
# list_workflow_actions.sh
#
# Lists GitHub Actions in use across a tenant's organizations - this is a basic view that includes action name, repo count, labels and security score
# and writes the results to a CSV file.
#
# Usage:
#   ./list_workflow_actions.sh --tenant <tenant> --token <stepsecurity-bearer-token> [--org <org>] [--output <file.csv>]
#
# Requirements: curl, jq

set -euo pipefail

API_BASE="https://agent.api.stepsecurity.io/v1"
OUTPUT="workflow_actions.csv"
TENANT=""
TOKEN=""
ORG=""

usage() {
  echo "Usage: $0 --tenant <tenant> --token <stepsecurity-token> [--org <org>] [--output <file>]"
  echo ""
  echo "  --tenant     StepSecurity tenant identifier"
  echo "  --token        StepSecurity API bearer token"
  echo "  --org          GitHub organization name (default: all orgs)"
  echo "  --output       Output CSV file (default: workflow_actions.csv)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)   TENANT="$2"; shift 2 ;;
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
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

# --- Helper: make authenticated API call ---
api_get() {
  local url="$1"
  curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    "$url"
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

# --- Step 2: Fetch workflow actions for each org ---
HEADER_WRITTEN=false
TOTAL_ACTIONS=0

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

  actions_with_owner=$(echo "$actions" | jq --arg owner "$owner" '
    [.[] | if type == "object" then . + {"owner": $owner} else {"value": ., "owner": $owner} end]
  ')

  if [ "$HEADER_WRITTEN" = false ]; then
    echo "$actions_with_owner" | jq -r '
      (.[0] | keys_unsorted) as $cols
      | ($cols | @csv),
        (.[] | [.[$cols[]]] | map(
          if type == "array" then (map(tostring) | join(";"))
          elif type == "object" then (tostring)
          elif . == null then ""
          else tostring
          end
        ) | @csv)
    ' > "$OUTPUT"
    HEADER_WRITTEN=true
  else
    echo "$actions_with_owner" | jq -r '
      (.[0] | keys_unsorted) as $cols
      | .[] | [.[$cols[]]] | map(
          if type == "array" then (map(tostring) | join(";"))
          elif type == "object" then (tostring)
          elif . == null then ""
          else tostring
          end
        ) | @csv
    ' >> "$OUTPUT"
  fi

  TOTAL_ACTIONS=$((TOTAL_ACTIONS + count))
  echo "  Found ${count} actions for '${owner}'."
done

if [ "$TOTAL_ACTIONS" -eq 0 ]; then
  echo "No workflow actions found for ${CONTEXT_INFO}."
  exit 0
fi

# --- Count unique actions ---
if [ "$HEADER_WRITTEN" = true ]; then
  header=$(head -1 "$OUTPUT")
  if echo "$header" | grep -qi '"name"'; then
    name_col=$(echo "$header" | tr ',' '\n' | grep -ni '"name"' | head -1 | cut -d: -f1)
    num_unique=$(tail -n +2 "$OUTPUT" | cut -d',' -f"$name_col" | sort -u | wc -l | tr -d ' ')
  else
    num_unique=$(tail -n +2 "$OUTPUT" | sort -u | wc -l | tr -d ' ')
  fi
else
  num_unique="unknown"
fi

echo ""
echo "${num_unique} unique GitHub Actions in use across ${CONTEXT_INFO}. Results written to '${OUTPUT}'."
