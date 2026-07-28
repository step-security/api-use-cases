#!/bin/bash

# Exports a StepSecurity tenant's access-control model as two CSVs:
#   1. roles -> permissions   (one row per role x permission)
#   2. users -> role grants   (one row per user x role assignment / entitlement)
#
# Covers the two built-in roles (admin, auditor) plus every custom role the
# tenant has defined.

set -euo pipefail

if [ $# -ne 4 ]; then
    echo "Usage: $0 <tenant> <api_key> <roles_output_file> <entitlements_output_file>"
    echo "Example: $0 'example-tenant' 'step_abc123...' 'roles_permissions.csv' 'role_entitlements.csv'"
    exit 1
fi

TENANT="$1"
API_KEY="$2"
ROLES_OUTPUT="$3"
ENTITLEMENTS_OUTPUT="$4"
BASE_URL="https://agent.api.stepsecurity.io/v1"

echo "Tenant:                 $TENANT"
echo "Roles output:           $ROLES_OUTPUT"
echo "Entitlements output:    $ENTITLEMENTS_OUTPUT"
echo "----------------------------------------"

# ---------------------------------------------------------------------------
# 1. Roles -> permissions
# ---------------------------------------------------------------------------
echo "Fetching roles and their permissions..."
ROLES_RESPONSE=$(curl -s -X 'GET' \
  "$BASE_URL/$TENANT/roles" \
  -H 'accept: application/json' \
  -H "Authorization: $API_KEY")

if ! echo "$ROLES_RESPONSE" | jq -e '.roles' >/dev/null 2>&1; then
    echo "Error: unexpected response while fetching roles:" >&2
    echo "$ROLES_RESPONSE" | head -c 500 >&2
    echo >&2
    exit 1
fi

# One row per (role, permission). role_type is "built-in" for the two system
# roles and "custom" for tenant-defined roles.
echo "role,role_type,role_id,description,permission" > "$ROLES_OUTPUT"
echo "$ROLES_RESPONSE" | jq -r '
  .roles[] as $r
  | $r.permissions[]
  | [ $r.name,
      (if $r.is_system then "built-in" else "custom" end),
      ($r.id // ""),
      ($r.description // ""),
      . ]
  | @csv' >> "$ROLES_OUTPUT"

ROLE_COUNT=$(echo "$ROLES_RESPONSE" | jq -r '.roles | length')
BUILTIN_COUNT=$(echo "$ROLES_RESPONSE" | jq -r '[.roles[] | select(.is_system)] | length')
CUSTOM_COUNT=$(echo "$ROLES_RESPONSE" | jq -r '[.roles[] | select(.is_system | not)] | length')
echo "  Roles: $ROLE_COUNT ($BUILTIN_COUNT built-in, $CUSTOM_COUNT custom)"
echo "----------------------------------------"

# ---------------------------------------------------------------------------
# 2. Users -> role grants (entitlements)
# ---------------------------------------------------------------------------
echo "Fetching users and their role assignments..."
USERS_RESPONSE=$(curl -s -X 'GET' \
  "$BASE_URL/$TENANT/users" \
  -H 'accept: application/json' \
  -H "Authorization: $API_KEY")

if ! echo "$USERS_RESPONSE" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Error: unexpected response while fetching users:" >&2
    echo "$USERS_RESPONSE" | head -c 500 >&2
    echo >&2
    exit 1
fi

# One row per user x role grant. A user with no grants is still emitted once
# with empty role columns so nobody is silently dropped from the inventory.
# organization/scope_targets are normalized across GitHub, GitLab and ADO
# policy shapes.
echo "user,auth_type,role,scope,platform,organization,scope_targets" > "$ENTITLEMENTS_OUTPUT"
echo "$USERS_RESPONSE" | jq -r '
  .[] as $u
  | ( ($u.policies // []) | if length == 0 then [null] else . end )[] as $p
  | [ $u.identifier,
      $u.auth_type,
      ($p.role // ""),
      ($p.scope // ""),
      ($p.type // ""),
      ($p.organization // $p.server // $p.ado_organization // ""),
      (( $p.repos // $p.projects // $p.ado_projects // [] ) | join("|")) ]
  | @csv' >> "$ENTITLEMENTS_OUTPUT"

USER_COUNT=$(echo "$USERS_RESPONSE" | jq -r 'length')
GRANT_COUNT=$(echo "$USERS_RESPONSE" | jq -r '[.[] | (.policies // []) | length] | add // 0')
echo "  Users: $USER_COUNT, role grants: $GRANT_COUNT"
echo "----------------------------------------"
echo "Done."
echo "  $ROLES_OUTPUT        ($(( $(wc -l < "$ROLES_OUTPUT") - 1 )) role-permission rows)"
echo "  $ENTITLEMENTS_OUTPUT ($(( $(wc -l < "$ENTITLEMENTS_OUTPUT") - 1 )) entitlement rows)"
