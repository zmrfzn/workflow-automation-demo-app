#!/usr/bin/env bash
# ─────────────────────────────────────────────
# pool-lab shared helpers.
# Sourced by provision.sh (instructor, macOS bash 3.2+) and by lab/bootstrap.sh
# (Instruqt VM). Keep it bash 3.2 compatible: no associative arrays, no ${v^^}, no mapfile.
# Requires: jq, curl
# ─────────────────────────────────────────────

print_step() { echo -e "\n\033[1;36m▶ $1\033[0m"; }
print_ok()   { echo -e "\033[1;32m✔ $1\033[0m"; }
print_err()  { echo -e "\033[1;31m✖ $1\033[0m" >&2; }
print_warn() { echo -e "\033[1;33m⚠ $1\033[0m"; }

# ── Checkpoint logs ────────────────────────────
# One coloured line per stage of a lab run, so a track log reads as a timeline:
#   ▶ [pool-lab 10:41:07 +3s] CLAIM      mapping labpool+002@… → INSTRUQT_LAB 02 - ReadOnly
# Follow a run with:  grep 'pool-lab ' /var/log/wfa-setup.log
# Each line carries the wall clock and the seconds since the script started. NO_COLOR=1 turns
# colour off. Never pass a secret: these lines go straight to the track log.
POOL_LAB_T0="${POOL_LAB_T0:-$(date +%s)}"
_checkpoint_line() { # _checkpoint_line <ansi colour> <symbol> <stage> <message>
  local ts
  ts="$(date +%H:%M:%S) +$(( $(date +%s) - POOL_LAB_T0 ))s"
  if [[ -n "${NO_COLOR:-}" ]]; then
    printf '%s [pool-lab %s] %-10s %s\n' "$2" "$ts" "$3" "$4"
  else
    printf '\033[%sm%s [pool-lab %s] %-10s %s\033[0m\n' "$1" "$2" "$ts" "$3" "$4"
  fi
}
checkpoint()      { _checkpoint_line "1;36" "▶" "$1" "$2"; }   # a stage starts
checkpoint_ok()   { _checkpoint_line "1;32" "✔" "$1" "$2"; }   # a stage finished
checkpoint_warn() { _checkpoint_line "1;33" "⚠" "$1" "$2"; }   # finished with a problem, run continues
checkpoint_fail() { _checkpoint_line "1;31" "✖" "$1" "$2"; }   # the run stops here

# Every lab group is named "<account name> - ReadOnly", same convention as MARS.
POOL_LAB_GROUP_SUFFIX=" - ReadOnly"

POOL_EMAIL_PREFIX="${POOL_EMAIL_PREFIX:-labpool+}"
POOL_AUTH_DOMAIN_NAME="${POOL_AUTH_DOMAIN_NAME:-Default}"
LAB_ACCOUNT_PREFIX="${LAB_ACCOUNT_PREFIX:-LAB}"

NR_ORG_ID="${NR_ORG_ID:-}"
NR_AUTH_DOMAIN_ID="${NR_AUTH_DOMAIN_ID:-}"

# ── GraphQL ────────────────────────────────────
_lab_graphql_url() {
  if [[ -n "${NR_GRAPHQL_URL:-}" ]]; then
    echo "$NR_GRAPHQL_URL"
  elif [[ "$(echo "${NR_REGION:-US}" | tr '[:lower:]' '[:upper:]')" == "EU" ]]; then
    echo "https://api.eu.newrelic.com/graphql"
  else
    echo "https://api.newrelic.com/graphql"
  fi
}

# gql <json body with .query and optional .variables> → prints the JSON response.
# Uses NEW_RELIC_API_KEY when set. Otherwise falls back to the `newrelic` CLI profile
# (best effort: output shape is normalised to {data|errors}).
gql() {
  local body="$1"
  if [[ -n "${NEW_RELIC_API_KEY:-}" ]]; then
    curl -sS --max-time 60 -X POST "$(_lab_graphql_url)" \
      -H "Content-Type: application/json" \
      -H "API-Key: ${NEW_RELIC_API_KEY}" \
      -d "$body" || echo '{"errors":[{"message":"curl request failed"}]}'
  elif command -v newrelic >/dev/null 2>&1; then
    local q v out
    q=$(jq -r '.query' <<<"$body")
    v=$(jq -c '.variables // {}' <<<"$body")
    out=$(newrelic nerdgraph query "$q" --variables "$v" 2>&1) \
      || { jq -n --arg m "$out" '{errors:[{message:$m}]}'; return 0; }
    if jq -e 'has("data") or has("errors")' >/dev/null 2>&1 <<<"$out"; then
      echo "$out"
    else
      jq -c '{data: .}' <<<"$out"
    fi
  else
    echo '{"errors":[{"message":"NEW_RELIC_API_KEY is not set and the newrelic CLI is not installed"}]}'
  fi
}

# gql_err <response> → first error message, or nothing when the response is clean.
gql_err() {
  jq -r '(.errors // []) | if length > 0 then .[0].message else empty end' <<<"$1" 2>/dev/null \
    || echo "unparseable response: $(head -c 200 <<<"$1")"
}

# gql_query <query-string> [variables-json] → response JSON
gql_query() {
  local vars="${2:-}"
  [[ -n "$vars" ]] || vars='{}'
  gql "$(jq -n --arg q "$1" --argjson v "$vars" '{query: $q, variables: $v}')"
}

# ── Org context ────────────────────────────────
resolve_context() {
  local org_result domain_result err
  org_result=$(gql '{"query": "{ actor { organization { id } } }"}')
  NR_ORG_ID=$(jq -r '.data.actor.organization.id // empty' <<<"$org_result" 2>/dev/null || true)
  if [[ -z "$NR_ORG_ID" ]]; then
    err=$(gql_err "$org_result")
    print_err "Failed to resolve NR org ID (check API key permissions): ${err:-$(head -c 200 <<<"$org_result")}"
    return 1
  fi

  domain_result=$(gql "$(jq -n --arg orgId "$NR_ORG_ID" --arg name "$POOL_AUTH_DOMAIN_NAME" \
    '{query: "query($filter: OrganizationAuthenticationDomainFilterInput!) { customerAdministration { authenticationDomains(filter: $filter) { items { id name } } } }",
      variables: {filter: {organizationId: {eq: $orgId}, name: {eq: $name}}}}')")
  NR_AUTH_DOMAIN_ID=$(jq -r '.data.customerAdministration.authenticationDomains.items[0].id // empty' <<<"$domain_result" 2>/dev/null || true)
  if [[ -z "$NR_AUTH_DOMAIN_ID" ]]; then
    print_err "Auth domain '${POOL_AUTH_DOMAIN_NAME}' not found: $(head -c 300 <<<"$domain_result")"
    return 1
  fi
}

# ── Pool users (paginated) ─────────────────────
# Prints a JSON array: { id, email, name, groups: { items: [{id, name}] } }
# restricted to emails starting with POOL_EMAIL_PREFIX.
fetch_users() {
  local all="[]" cursor="" body result page next
  while true; do
    if [[ -z "$cursor" ]]; then
      body=$(jq -n --arg d "$NR_AUTH_DOMAIN_ID" \
        '{query: "query($filter: MultiTenantIdentityUserFilterInput!) { customerAdministration { users(filter: $filter) { items { id email name groups { items { id name } } } nextCursor } } }",
          variables: {filter: {authenticationDomainId: {eq: $d}}}}')
    else
      body=$(jq -n --arg d "$NR_AUTH_DOMAIN_ID" --arg cursor "$cursor" \
        '{query: "query($filter: MultiTenantIdentityUserFilterInput!, $cursor: String) { customerAdministration { users(filter: $filter, cursor: $cursor) { items { id email name groups { items { id name } } } nextCursor } } }",
          variables: {filter: {authenticationDomainId: {eq: $d}}, cursor: $cursor}}')
    fi
    result=$(gql "$body")
    if [[ -n "$(gql_err "$result")" ]]; then
      print_err "Failed to query users: $(gql_err "$result")"
      return 1
    fi
    page=$(jq -c --arg p "$POOL_EMAIL_PREFIX" \
      '[.data.customerAdministration.users.items[] | select(.email | startswith($p))]' <<<"$result")
    next=$(jq -r '.data.customerAdministration.users.nextCursor // empty' <<<"$result")
    all=$(jq -c -n --argjson a "$all" --argjson b "$page" '$a + $b')
    [[ -n "$next" ]] || break
    cursor="$next"
  done
  echo "$all"
}

# Prints a JSON array [{id, name}] of the lab groups: names that start with
# "<LAB_ACCOUNT_PREFIX> " and end with " - ReadOnly".
fetch_lab_groups() {
  local all="[]" cursor="" body result page next
  while true; do
    if [[ -z "$cursor" ]]; then
      body=$(jq -n --arg o "$NR_ORG_ID" --arg d "$NR_AUTH_DOMAIN_ID" \
        '{query: "query($filter: MultiTenantIdentityGroupFilterInput!) { customerAdministration { groups(filter: $filter) { items { id name } nextCursor } } }",
          variables: {filter: {organizationId: {eq: $o}, authenticationDomainId: {eq: $d}}}}')
    else
      body=$(jq -n --arg o "$NR_ORG_ID" --arg d "$NR_AUTH_DOMAIN_ID" --arg cursor "$cursor" \
        '{query: "query($filter: MultiTenantIdentityGroupFilterInput!, $cursor: String) { customerAdministration { groups(filter: $filter, cursor: $cursor) { items { id name } nextCursor } } }",
          variables: {filter: {organizationId: {eq: $o}, authenticationDomainId: {eq: $d}}, cursor: $cursor}}')
    fi
    result=$(gql "$body")
    if [[ -n "$(gql_err "$result")" ]]; then
      print_err "Failed to query groups: $(gql_err "$result")"
      return 1
    fi
    page=$(jq -c --arg p "${LAB_ACCOUNT_PREFIX} " --arg s "$POOL_LAB_GROUP_SUFFIX" \
      '[.data.customerAdministration.groups.items[] | select((.name | startswith($p)) and (.name | endswith($s)))]' <<<"$result")
    next=$(jq -r '.data.customerAdministration.groups.nextCursor // empty' <<<"$result")
    all=$(jq -c -n --argjson a "$all" --argjson b "$page" '$a + $b')
    [[ -n "$next" ]] || break
    cursor="$next"
  done
  echo "$all"
}

# ── Membership mutations ───────────────────────
# add_user_to_group <user-id> <group-id>   (returns 1 and prints on API error)
add_user_to_group() {
  local result
  result=$(gql "$(jq -n --arg g "$2" --arg u "$1" \
    '{query: "mutation($opts: UserManagementUsersGroupsInput) { userManagementAddUsersToGroups(addUsersToGroupsOptions: $opts) { groups { id displayName } } }",
      variables: {opts: {groupIds: [$g], userIds: [$u]}}}')")
  if [[ -n "$(gql_err "$result")" ]]; then
    print_err "Failed to add user to group: $(gql_err "$result")"
    return 1
  fi
}

# remove_user_from_group <user-id> <group-id>   (returns 1 and prints on API error)
remove_user_from_group() {
  local result
  result=$(gql "$(jq -n --arg g "$2" --arg u "$1" \
    '{query: "mutation($opts: UserManagementUsersGroupsInput!) { userManagementRemoveUsersFromGroups(removeUsersFromGroupsOptions: $opts) { groups { id } } }",
      variables: {opts: {groupIds: [$g], userIds: [$u]}}}')")
  if [[ -n "$(gql_err "$result")" ]]; then
    print_err "Failed to remove user from group: $(gql_err "$result")"
    return 1
  fi
}

# ── Account / key lookups ──────────────────────
# fetch_accounts → JSON array [{id, name}] of every account the key can see.
fetch_accounts() {
  local result
  result=$(gql '{"query": "{ actor { accounts { id name } } }"}')
  if [[ -n "$(gql_err "$result")" ]]; then
    print_err "Failed to list accounts: $(gql_err "$result")"
    return 1
  fi
  jq -c '[.data.actor.accounts[] | {id, name}]' <<<"$result"
}

# account_id_by_name <exact name> → account id on stdout (empty when absent)
account_id_by_name() {
  local accounts
  accounts=$(fetch_accounts) || return 1
  jq -r --arg n "$1" '[.[] | select(.name == $n)] | first | .id // empty' <<<"$accounts"
}

# license_key_for_account <account id> → the account's ingest LICENSE key on stdout (empty when none)
license_key_for_account() {
  local result
  result=$(gql_query 'query($acct: Int!) { actor { apiAccess { keySearch(query: {types: [INGEST], scope: {accountIds: [$acct], ingestTypes: [LICENSE]}}) { keys { ... on ApiAccessIngestKey { id key name ingestType accountId } } } } } }' \
    "$(jq -n --argjson a "$1" '{acct: $a}')")
  if [[ -n "$(gql_err "$result")" ]]; then
    print_err "Failed to look up license key for account $1: $(gql_err "$result")"
    return 1
  fi
  jq -r '[.data.actor.apiAccess.keySearch.keys[]? | select(.ingestType == "LICENSE")] | first | .key // empty' <<<"$result"
}

# group_account_grants <group id> → JSON array [{roleId, roleName, accountId}] of the group's
# ACCOUNT-scoped grants (paginated). Grants are not a field on groups: they come from
# customerAdministration.grants (VERIFIED live 2026-10-30; role.id is an Int, scope.id a String).
group_account_grants() {
  local all="[]" cursor="" result page next
  while true; do
    result=$(gql_query 'query($o: ID!, $g: ID!, $cursor: String) { customerAdministration { grants(cursor: $cursor, filter: {organizationId: {eq: $o}, groupId: {eq: $g}}) { nextCursor items { role { id name } scope { id type } } } } }' \
      "$(jq -n --arg o "$NR_ORG_ID" --arg g "$1" --arg cursor "$cursor" '{o: $o, g: $g, cursor: (if $cursor == "" then null else $cursor end)}')")
    if [[ -n "$(gql_err "$result")" ]]; then
      print_err "Failed to query grants for group $1: $(gql_err "$result")"
      return 1
    fi
    page=$(jq -c '[.data.customerAdministration.grants.items[]? | select(.scope.type == "ACCOUNT")
                   | {roleId: (.role.id | tostring), roleName: (.role.name // ""), accountId: (.scope.id | tostring)}]' <<<"$result")
    all=$(jq -c -n --argjson a "$all" --argjson b "$page" '$a + $b')
    next=$(jq -r '.data.customerAdministration.grants.nextCursor // empty' <<<"$result")
    [[ -n "$next" ]] || break
    cursor="$next"
  done
  echo "$all"
}

# ── Agent variable store (Instruqt) ────────────
# The Instruqt agent CLI exits 0 even when a write fails, so every write is verified by
# readback and retried (same approach as mars-program/track_scripts/setup-k8s).
# When the agent CLI is absent (local runs, tests) a file store under POOL_LAB_VAR_DIR is used.
AGENT_VAR_MAX_ATTEMPTS="${AGENT_VAR_MAX_ATTEMPTS:-5}"
POOL_LAB_VAR_DIR="${POOL_LAB_VAR_DIR:-/tmp/pool-lab-vars}"

agent_var_set() {
  local key="$1" value="$2" attempt=1 out got
  if ! command -v agent >/dev/null 2>&1; then
    mkdir -p "$POOL_LAB_VAR_DIR" && printf '%s' "$value" > "$POOL_LAB_VAR_DIR/$key"
    return 0
  fi
  while true; do
    out="$(agent variable set "$key" "$value" 2>&1)"
    if [[ "$out" != *"Failed to set value"* ]]; then
      got="$(agent variable get "$key" 2>/dev/null || true)"
      [[ "$got" == "$value" ]] && return 0
    fi
    if (( attempt >= AGENT_VAR_MAX_ATTEMPTS )); then
      echo "❌ ERROR: Could not set agent variable '$key' after ${AGENT_VAR_MAX_ATTEMPTS} attempts${out:+: }${out}"
      return 1
    fi
    echo "  ⚠️  agent variable set '$key' failed verification (attempt ${attempt}/${AGENT_VAR_MAX_ATTEMPTS}), retrying in $((attempt * 2))s..."
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

agent_var_get() {
  local key="$1" attempt=1 out
  if ! command -v agent >/dev/null 2>&1; then
    [[ -f "$POOL_LAB_VAR_DIR/$key" ]] && cat "$POOL_LAB_VAR_DIR/$key" && return 0
    return 1
  fi
  while true; do
    if out="$(agent variable get "$key" 2>/tmp/agent_var_err)"; then
      printf '%s' "$out"
      return 0
    fi
    if ! grep -qiE 'connection refused|dial tcp|connect:' /tmp/agent_var_err 2>/dev/null \
       || (( attempt >= AGENT_VAR_MAX_ATTEMPTS )); then
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}
