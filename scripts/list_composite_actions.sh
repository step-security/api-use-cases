#!/usr/bin/env bash
#
# list_composite_actions.sh
#
# Lists every composite GitHub Action in use across an organization and, for
# each one, recursively expands the actions nested inside it (the `uses:` steps
# in the composite's action.yml) until only leaf node/docker actions remain.
#
# It answers: "which of the actions we depend on are composite actions, and what
# actions do those composites pull in transitively?"
#
# Usage:
#   ./list_composite_actions.sh --org <org> --token <stepsecurity-bearer-token> \
#       [--tree-output <file.txt>] [--csv-output <file.csv>] [--no-recurse]
#
# Requirements: curl, jq, base64
#
# How it works (two public StepSecurity API endpoints):
#   1. GET  /v1/github/<org>/actions/workflow-actions   -> the org's action inventory
#   2. POST /v1/github/actions/action-details           -> per-action metadata,
#         including "actionType" (composite|node24|docker|...) and, for composites,
#         "composite_actions.actions" (the nested `uses:` list).
#
# Recursion re-runs step 2 on each nested action, memoizing results, until no new
# composites are found. Cycles are detected and stopped.

set -euo pipefail

API_BASE="https://agent.api.stepsecurity.io/v1"
ORG=""
TOKEN=""
TREE_OUTPUT="composite_actions_tree.txt"
CSV_OUTPUT="composite_actions.csv"
RECURSE=1

usage() {
  echo "Usage: $0 --org <org> --token <stepsecurity-token> [--tree-output <file>] [--csv-output <file>] [--no-recurse]"
  echo ""
  echo "  --org           GitHub organization name (required)"
  echo "  --token         StepSecurity API bearer token (required)"
  echo "  --tree-output   Indented tree text file (default: composite_actions_tree.txt)"
  echo "  --csv-output    Flat CSV: root_composite,depth,action,action_type,parent (default: composite_actions.csv)"
  echo "  --no-recurse    Only list direct nested actions (one level), do not expand transitively"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)          ORG="$2"; shift 2 ;;
    --token)        TOKEN="$2"; shift 2 ;;
    --tree-output)  TREE_OUTPUT="$2"; shift 2 ;;
    --csv-output)   CSV_OUTPUT="$2"; shift 2 ;;
    --no-recurse)   RECURSE=0; shift ;;
    *)              usage ;;
  esac
done

[[ -z "$ORG" || -z "$TOKEN" ]] && usage

for cmd in curl jq base64; do
  command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not installed."; exit 1; }
done

# Memoization cache: one file per action name, holding its action-details JSON.
CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$CACHE_DIR"' EXIT

cache_key() { printf '%s' "$1" | shasum | awk '{print $1}'; }

# Strip the @ref (sha/tag/branch) from a `uses:` value, keeping owner/repo[/path].
strip_ref() { printf '%s' "${1%%@*}"; }

# Fetch (and cache) action-details for one action name. Echoes the JSON body ({} on error).
get_details() {
  local name="$1"
  local f="${CACHE_DIR}/$(cache_key "$name").json"
  if [[ -s "$f" ]]; then cat "$f"; return; fi
  local body http_code response
  response=$(curl -s -w $'\n%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "x-github-org: ${ORG}" \
    -d "$(jq -nc --arg n "$name" '{name:$n}')" \
    "${API_BASE}/github/actions/action-details")
  http_code=$(printf '%s' "$response" | tail -n1)
  body=$(printf '%s' "$response" | sed '$d')
  [[ "$http_code" != "200" ]] && body="{}"
  printf '%s' "$body" > "$f"
  printf '%s' "$body"
}

# Recursively print a composite's tree and append CSV rows.
# args: action_name  display_label  depth  root  parent  visited_path
render() {
  local name="$1" label="$2" depth="$3" root="$4" parent="$5" path="$6"
  local details atype nested
  details=$(get_details "$name")
  atype=$(printf '%s' "$details" | jq -r '.actionType // "unresolved"')

  local indent=""; local i; for ((i=0;i<depth;i++)); do indent+="  "; done
  echo "${indent}- ${label} [${atype}]" >> "$TREE_OUTPUT"
  # CSV: root_composite,depth,action,action_type,parent
  jq -nr --arg r "$root" --arg d "$depth" --arg a "$label" --arg t "$atype" --arg p "$parent" \
    '[$r,($d|tonumber),$a,$t,$p]|@csv' >> "$CSV_OUTPUT"

  # Cycle guard.
  case "|${path}|" in *"|${name}|"*) echo "${indent}  (cycle -> stop)" >> "$TREE_OUTPUT"; return ;; esac

  nested=$(printf '%s' "$details" | jq -r '(.composite_actions.actions // [])[]')
  [[ -z "$nested" ]] && return
  [[ "$RECURSE" -eq 0 && "$depth" -ge 1 ]] && return

  local child child_name
  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    child_name=$(strip_ref "$child")
    render "$child_name" "$child" $((depth+1)) "$root" "$label" "${path}|${name}"
  done <<< "$nested"
}

echo "Fetching action inventory for '${ORG}'..."
inv_response=$(curl -s -w $'\n%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json" \
  "${API_BASE}/github/${ORG}/actions/workflow-actions")
http_code=$(printf '%s' "$inv_response" | tail -n1)
inv_body=$(printf '%s' "$inv_response" | sed '$d')
[[ "$http_code" != "200" ]] && { echo "Error fetching inventory: HTTP ${http_code}"; echo "$inv_body"; exit 1; }

ACTIONS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ACTIONS+=("$line")
done < <(printf '%s' "$inv_body" | jq -r '.[].action')
TOTAL=${#ACTIONS[@]}
echo "Found ${TOTAL} actions in use. Checking each for actionType=composite..."

# Reset outputs.
: > "$TREE_OUTPUT"
echo "root_composite,depth,action,action_type,parent" > "$CSV_OUTPUT"

COMPOSITE_COUNT=0
PROCESSED=0
for action in "${ACTIONS[@]}"; do
  PROCESSED=$((PROCESSED+1))
  (( PROCESSED % 50 == 0 )) && echo "  ...scanned ${PROCESSED}/${TOTAL}"
  details=$(get_details "$action")
  atype=$(printf '%s' "$details" | jq -r '.actionType // ""')
  [[ "$atype" != "composite" ]] && continue
  COMPOSITE_COUNT=$((COMPOSITE_COUNT+1))
  render "$action" "$action" 0 "$action" "" ""
  echo "" >> "$TREE_OUTPUT"
done

echo ""
echo "Done. ${COMPOSITE_COUNT} composite actions of ${TOTAL} total."
echo "Tree written to '${TREE_OUTPUT}'."
echo "Flat CSV written to '${CSV_OUTPUT}'."
