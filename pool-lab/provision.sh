#!/usr/bin/env bash
# ─────────────────────────────────────────────
# pool-lab provisioning CLI (instructor, run BEFORE the workshop).
# Creates the pool users and the pre-provisioned sub-accounts (admin grant, ingest LICENSE
# key, "<account> - ReadOnly" group + read_only grant). The lab VM later only claims a free
# user + a free group, so the slow grant-propagation wait happens here, once.
#
# Usage: ./provision.sh <users|accounts> <subcommand> [args] [--dry-run] [--yes]
#        ./provision.sh --help
# Requires: jq, curl.  Targets macOS bash 3.2 as well as Linux bash.
#
# Every GraphQL mutation string below that is marked "UNVERIFIED shape" has NOT been
# checked against the live schema: confirm via introspection before the first real run
# (and always try --dry-run first).
# ─────────────────────────────────────────────

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROVISION_MAIN=0
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _PROVISION_MAIN=1
  set -euo pipefail
  # Auto-load .env from the pool-lab directory if present (before common.sh reads defaults)
  if [[ -f "$_SCRIPT_DIR/.env" ]]; then
    set -o allexport
    # shellcheck source=/dev/null
    source "$_SCRIPT_DIR/.env"
    set +o allexport
  fi
fi

# shellcheck source=lib/common.sh
source "$_SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/claim.sh
source "$_SCRIPT_DIR/lib/claim.sh"
# shellcheck source=lib/scrub.sh
source "$_SCRIPT_DIR/lib/scrub.sh"

# ── Config (env, with defaults) ────────────────
POOL_USER_DOMAIN="${POOL_USER_DOMAIN:-}"
POOL_USER_COUNT="${POOL_USER_COUNT:-20}"
POOL_USER_NAME_PREFIX="${POOL_USER_NAME_PREFIX:-Lab User}"
LAB_ACCOUNT_COUNT="${LAB_ACCOUNT_COUNT:-20}"
LAB_ACCOUNT_REGION="${LAB_ACCOUNT_REGION:-us01}"
LAB_ADMIN_GROUP_NAME="${LAB_ADMIN_GROUP_NAME:-Admin}"
LAB_ADMIN_ROLE="${LAB_ADMIN_ROLE:-all_product_admin}"
LAB_READONLY_ROLE="${LAB_READONLY_ROLE:-read_only}"
LAB_PROPAGATION_POLLS="${LAB_PROPAGATION_POLLS:-60}"
LAB_PROPAGATION_INTERVAL="${LAB_PROPAGATION_INTERVAL:-10}"
LAB_CANCEL_PAUSE="${LAB_CANCEL_PAUSE:-5}"
LAB_USER_PASSWORD_SECRET="${LAB_USER_PASSWORD_SECRET:-NR_LAB_USER_PASSWORD}"

DRY_RUN=0
ASSUME_YES=0
HEADLESS=0
FORCE=0
POS=()

# Looked up once per `accounts create` run (see _load_lookup_ids).
ADMIN_GROUP_ID=""
ADMIN_ROLE_ID=""
RO_ROLE_ID=""

usage() {
  cat <<EOF
pool-lab provisioning (run before the workshop)

Usage: provision.sh <group> <subcommand> [args] [--dry-run] [--yes]

  users create              Create POOL_USER_COUNT pool users (idempotent; existing are skipped)
  users status              Show free vs occupied pool users
  users free [email]        Remove pool users from the lab groups (never deletes the groups)
  users delete              Delete all pool users (asks you to type 'yes')

  Browser tooling (Selenium; no API key needed; setup: see selenium/README.md):
  users accept-invites      Open each accept link in invites.json and set the shared password
  users validate-passwords  Read-only: log in as every pool user to verify POOL_PASSWORD works
  users reset-passwords     Log in as every pool user and change POOL_CURRENT_PASSWORD -> POOL_NEW_PASSWORD

  accounts create [N]       Create N (default LAB_ACCOUNT_COUNT) sub-accounts "<LAB_ACCOUNT_PREFIX> NN",
                            each with admin grant, ingest LICENSE key, "<name> - ReadOnly" group
                            and its LAB_READONLY_ROLE grant. Idempotent: finished steps are skipped.
  accounts status           Table of lab accounts: group, claimed-by / free, license key yes/no
  accounts scrub <account|--all>
                            Delete everything a learner created in a lab account (alert policies, muting
                            rules, alert workflows, channels, destinations, Workflow Automation definitions,
                            dashboards, entities, other users' user keys) so the next learner starts blank.
                            <account> is an id or a name ("INSTRUQT_LAB 02"). Shows a dry pass and asks 'yes'.
                            Skips an account whose group has a member (a lab in progress) unless --force.
                            The lab cleanup runs the same scrub; use this to retry one that failed.
  accounts destroy          Remove members, delete groups, cancel each account twice (asks 'yes')

  pair claim [email] [account name]
                            Test the lab-time mapping without Instruqt: claim a free pool user + free lab
                            group (random, or the ones you name), then print the account id and whether a
                            license key is readable. Undo with 'users free <email>'.

  help, --help              This text

Global flags (anywhere after the subcommand):
  --dry-run                 Read-only lookups only; print what WOULD be created/skipped/removed
  --yes, -y                 Skip confirmation prompts
  --headless                Browser commands only: run Chrome without a window
  --force                   accounts scrub: also scrub an account that is claimed right now

Environment (default):
  NEW_RELIC_API_KEY         User API key (else the 'newrelic' CLI profile is used)
  NR_REGION                 US or EU (US)
  POOL_EMAIL_PREFIX         (labpool+)    pool address = <prefix>NNN@<POOL_USER_DOMAIN>
  POOL_USER_DOMAIN          REQUIRED for 'users create' and 'users delete'
  POOL_USER_COUNT           (20)
  POOL_USER_NAME_PREFIX     ("Lab User")
  POOL_AUTH_DOMAIN_NAME     (Default)
  LAB_ACCOUNT_PREFIX        (LAB)         letters, digits, space, _ and - only
  LAB_ACCOUNT_COUNT         (20)
  LAB_ACCOUNT_REGION        (us01)
  LAB_ADMIN_GROUP_NAME      (Admin)       group that gets admin on every new account
  LAB_ADMIN_ROLE            (all_product_admin)
  LAB_READONLY_ROLE         (read_only)
  LAB_PROPAGATION_POLLS     (60)          visibility polls per new account
  LAB_PROPAGATION_INTERVAL  (10)          seconds between polls
  LAB_CANCEL_PAUSE          (5)           seconds between the two account cancellations
  LAB_USER_PASSWORD_SECRET  (NR_LAB_USER_PASSWORD) Instruqt secret name for the shared pool password
  POOL_PASSWORD             Browser commands: the shared password expected by validate-passwords
  POOL_CURRENT_PASSWORD     Browser commands: current shared password (reset-passwords)
  POOL_NEW_PASSWORD         Browser commands: new shared password (reset-passwords; validate fallback)
  POOL_INVITES_FILE         Browser commands: invites JSON (invites.json next to this script)
  POOL_LAB_PYTHON           Browser commands: python to use (selenium/.venv/bin/python)
EOF
}

# ── Small helpers ──────────────────────────────
# Single choke point for GraphQL writes: refuses to run during --dry-run, so a bug in a
# dry-run code path cannot mutate anything.
gql_mut() { # gql_mut <query> [variables-json]
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    print_err "internal error: mutation attempted during --dry-run (blocked)"
    return 99
  fi
  gql_query "$@"
}

_confirm_yes() { # _confirm_yes <prompt>   → 0 only when the user typed 'yes' (or --yes)
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local answer
  read -rp "$1 Type 'yes' to continue: " answer || return 1
  [[ "$answer" == "yes" ]]
}

_require_positive_int() { # _require_positive_int <value> <label>
  if ! [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" -lt 1 ]]; then
    print_err "$2 must be a positive integer (got '$1')"
    return 1
  fi
}

_require_user_domain() {
  if [[ -z "$POOL_USER_DOMAIN" ]]; then
    print_err "POOL_USER_DOMAIN is not set (the mail domain for ${POOL_EMAIL_PREFIX}NNN@<domain>). Export it or put it in pool-lab/.env."
    return 1
  fi
}

_validate_prefix() {
  local re='^[A-Za-z0-9 _-]+$'
  if ! [[ "$LAB_ACCOUNT_PREFIX" =~ $re ]]; then
    print_err "LAB_ACCOUNT_PREFIX '${LAB_ACCOUNT_PREFIX}' may contain only letters, digits, space, _ and - (it is inlined into GraphQL)"
    return 1
  fi
}

_validate_account_config() { # also guards values that get inlined into GraphQL
  local re='^[A-Za-z0-9._-]+$'
  _validate_prefix || return 1
  if ! [[ "$LAB_ACCOUNT_REGION" =~ $re ]]; then
    print_err "LAB_ACCOUNT_REGION '${LAB_ACCOUNT_REGION}' looks invalid"
    return 1
  fi
}

_ctx() {
  print_step "Resolving org context"
  resolve_context || return 1
  echo "  Org ID: $NR_ORG_ID"
  echo "  Auth domain ID: $NR_AUTH_DOMAIN_ID"
}

_group_id_by_name() { # _group_id_by_name <exact name> → id on stdout (empty when absent)
  local result
  result=$(gql_query 'query($filter: MultiTenantIdentityGroupFilterInput!) { customerAdministration { groups(filter: $filter) { items { id name } nextCursor } } }' \
    "$(jq -n --arg o "$NR_ORG_ID" --arg d "$NR_AUTH_DOMAIN_ID" --arg n "$1" \
      '{filter: {organizationId: {eq: $o}, authenticationDomainId: {eq: $d}, name: {eq: $n}}}')")
  if [[ -n "$(gql_err "$result")" ]]; then
    print_err "Failed to query group '$1': $(gql_err "$result")"
    return 1
  fi
  jq -r --arg n "$1" '[.data.customerAdministration.groups.items[]? | select(.name == $n)] | first | .id // empty' <<<"$result"
}

# ═════════════════════ users ═════════════════════

cmd_users_create() {
  _require_user_domain || return 1
  _require_positive_int "$POOL_USER_COUNT" POOL_USER_COUNT || return 1
  _ctx || return 1

  print_step "Fetching existing pool users"
  local existing
  existing=$(fetch_users) || return 1

  print_step "Creating pool users ${POOL_EMAIL_PREFIX}001 through ${POOL_EMAIL_PREFIX}$(printf '%03d' "$POOL_USER_COUNT") (@${POOL_USER_DOMAIN})"
  local created=0 skipped=0 failed=0 i email name result err new_id
  for i in $(seq -f "%03g" 1 "$POOL_USER_COUNT"); do
    email="${POOL_EMAIL_PREFIX}${i}@${POOL_USER_DOMAIN}"
    name="${POOL_USER_NAME_PREFIX} ${i}"

    if jq -e --arg e "$email" 'any(.[]; (.email | ascii_downcase) == ($e | ascii_downcase))' <<<"$existing" >/dev/null; then
      echo "  skip    $email"
      skipped=$(( skipped + 1 ))
      continue
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
      echo "  WOULD create $email"
      created=$(( created + 1 ))
      continue
    fi

    result=$(gql_mut 'mutation($opts: UserManagementCreateUser!) { userManagementCreateUser(createUserOptions: $opts) { createdUser { id email name } } }' \
      "$(jq -n --arg d "$NR_AUTH_DOMAIN_ID" --arg e "$email" --arg n "$name" \
        '{opts: {authenticationDomainId: $d, email: $e, name: $n, userType: "FULL_USER_TIER"}}')")
    err=$(gql_err "$result")
    if [[ -n "$err" ]]; then
      if grep -qiE 'already exists|duplicate|conflict' <<<"$err"; then
        echo "  skip    $email (already exists)"
        skipped=$(( skipped + 1 ))
      else
        print_warn "  fail    $email: $err"
        failed=$(( failed + 1 ))
      fi
    else
      new_id=$(jq -r '.data.userManagementCreateUser.createdUser.id // empty' <<<"$result")
      print_ok "  created $email (ID: $new_id)"
      created=$(( created + 1 ))
    fi
  done

  echo ""
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "Dry run. Would create: $created  |  Skipped: $skipped"
    return 0
  fi
  echo "Created: $created  |  Skipped: $skipped  |  Failed: $failed"
  if [[ "$created" -gt 0 ]]; then
    print_warn "Manual step: each new address receives a New Relic invite email."
    echo "  1. Accept every invite (open the link, set a password)."
    echo "  2. Use the SAME shared password for all pool users."
    echo "  3. Store that password as the Instruqt secret named: ${LAB_USER_PASSWORD_SECRET}"
  fi
  if [[ "$failed" -gt 0 ]]; then
    print_warn "$failed user(s) failed to create"
    return 1
  fi
}

cmd_users_status() {
  _ctx || return 1
  print_step "Fetching pool users"
  local users total free_count occupied_count
  users=$(fetch_users) || return 1
  total=$(jq 'length' <<<"$users")
  free_count=$(jq '[.[] | select((.groups.items // []) | length == 0)] | length' <<<"$users")
  occupied_count=$(jq '[.[] | select((.groups.items // []) | length > 0)] | length' <<<"$users")

  echo ""
  echo -e "\033[1;32m── Free ($free_count) ──────────────────────────────────────────\033[0m"
  jq -r '[.[] | select((.groups.items // []) | length == 0) | .email] | sort | .[]' <<<"$users" | sed 's/^/  /'
  echo ""
  echo -e "\033[1;33m── Occupied ($occupied_count) ───────────────────────────────────\033[0m"
  jq -r '[.[] | select((.groups.items // []) | length > 0) | "\(.email)  →  \(.groups.items | map(.name) | join(", "))"] | sort | .[]' <<<"$users" | sed 's/^/  /'
  echo ""
  echo "Total: $total  |  Free: $free_count  |  Occupied: $occupied_count"
}

# users free [email]: remove pool users from the LAB groups only. Groups are pre-made and
# reused, so this never deletes a group (and never touches non-lab group memberships).
cmd_users_free() {
  local target="${1:-}"
  _ctx || return 1

  print_step "Fetching pool users and lab groups"
  local users groups lab_ids occupied count
  users=$(fetch_users) || return 1
  groups=$(fetch_lab_groups) || return 1
  lab_ids=$(jq -c '[.[].id]' <<<"$groups")

  if [[ -n "$target" ]] && ! jq -e --arg e "$target" 'any(.[]; (.email | ascii_downcase) == ($e | ascii_downcase))' <<<"$users" >/dev/null; then
    print_err "No pool user with email '$target' (prefix '${POOL_EMAIL_PREFIX}')"
    return 1
  fi

  occupied=$(jq -c --argjson lab "$lab_ids" --arg e "$target" \
    '[.[] | select($e == "" or ((.email | ascii_downcase) == ($e | ascii_downcase)))
          | ((.groups.items // []) | map(select(.id as $g | ($lab | index($g)) != null))) as $lg
          | ((.groups.items // []) | map(select(.id as $g | ($lab | index($g)) == null))) as $og
          | select(($lg | length) > 0)
          | {id, email, lg: $lg, og: $og}]' <<<"$users")
  count=$(jq 'length' <<<"$occupied")

  if [[ "$count" -eq 0 ]]; then
    print_ok "Nothing to free: no pool user${target:+ ($target)} is in a lab group."
    return 0
  fi

  echo ""
  jq -r '.[] | "  \(.email)  →  \(.lg | map(.name) | join(", "))"' <<<"$occupied"
  echo ""
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "Dry run. Would remove $count user(s) from their lab group(s). Groups are never deleted."
    return 0
  fi
  if [[ -z "$target" ]]; then
    _confirm_yes "Free all $count occupied user(s)?" || { print_warn "Aborted."; return 0; }
  fi

  print_step "Freeing pool users (membership removal only; groups are kept)"
  local freed=0 failed=0 user_json uid email user_ok gid gname other
  while IFS= read -r user_json <&3; do
    uid=$(jq -r '.id' <<<"$user_json")
    email=$(jq -r '.email' <<<"$user_json")
    user_ok=1
    while IFS=$'\t' read -r gid gname <&4; do
      if remove_user_from_group "$uid" "$gid"; then
        echo "  removed $email from '$gname'"
      else
        user_ok=0
      fi
    done 4< <(jq -r '.lg[] | [.id, .name] | @tsv' <<<"$user_json")
    other=$(jq -r '.og | map(.name) | join(", ")' <<<"$user_json")
    if [[ -n "$other" ]]; then
      print_warn "  $email is also in non-lab group(s) left untouched: $other"
    fi
    if [[ "$user_ok" == 1 ]]; then
      print_ok "  freed $email"
      freed=$(( freed + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
  done 3< <(jq -c '.[]' <<<"$occupied")

  echo ""
  echo "Freed: $freed  |  Failed: $failed"
  if [[ "$failed" -gt 0 ]]; then return 1; fi
}

cmd_users_delete() {
  _require_user_domain || return 1
  _ctx || return 1

  print_step "Fetching pool users"
  local users total
  # Only addresses on POOL_USER_DOMAIN are ever deleted.
  users=$(fetch_users) || return 1
  users=$(jq -c --arg suf "@${POOL_USER_DOMAIN}" '[.[] | select(.email | ascii_downcase | endswith($suf | ascii_downcase))]' <<<"$users")
  total=$(jq 'length' <<<"$users")

  if [[ "$total" -eq 0 ]]; then
    print_ok "No pool users found. Nothing to delete."
    return 0
  fi

  echo ""
  echo "Found $total pool user(s) to delete:"
  jq -r '[.[].email] | sort | .[]' <<<"$users" | sed 's/^/  /'
  echo ""
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "Dry run. Would remove them from all groups and delete them."
    return 0
  fi
  _confirm_yes "This permanently deletes all $total pool users." || { print_warn "Aborted."; return 0; }

  print_step "Deleting pool users"
  local deleted=0 failed=0 user_json uid email gid result err
  while IFS= read -r user_json <&3; do
    uid=$(jq -r '.id' <<<"$user_json")
    email=$(jq -r '.email' <<<"$user_json")
    while IFS= read -r gid <&4; do
      remove_user_from_group "$uid" "$gid" || true
    done 4< <(jq -r '(.groups.items // [])[] | .id' <<<"$user_json")

    result=$(gql_mut 'mutation($opts: UserManagementDeleteUser!) { userManagementDeleteUser(deleteUserOptions: $opts) { deletedUser { id } } }' \
      "$(jq -n --arg id "$uid" '{opts: {id: $id}}')")
    err=$(gql_err "$result")
    if [[ -n "$err" ]]; then
      print_warn "  fail    $email: $err"
      failed=$(( failed + 1 ))
    else
      print_ok "  deleted $email"
      deleted=$(( deleted + 1 ))
    fi
  done 3< <(jq -c '.[]' <<<"$users")

  echo ""
  echo "Deleted: $deleted  |  Failed: $failed"
  if [[ "$failed" -gt 0 ]]; then return 1; fi
}

# ═════════════════════ accounts ═════════════════════

# Resolve the admin group id plus admin and learner (LAB_READONLY_ROLE) role ids once (read-only queries).
_load_lookup_ids() {
  local roles
  ADMIN_GROUP_ID=$(_group_id_by_name "$LAB_ADMIN_GROUP_NAME") || return 1
  if [[ -z "$ADMIN_GROUP_ID" ]]; then
    print_err "Admin group '${LAB_ADMIN_GROUP_NAME}' not found in the '${POOL_AUTH_DOMAIN_NAME}' auth domain (set LAB_ADMIN_GROUP_NAME)"
    return 1
  fi
  roles=$(gql '{"query": "{ actor { organization { authorizationManagement { roles { roles { id name displayName type } } } } } }"}')
  if [[ -n "$(gql_err "$roles")" ]]; then
    print_err "Failed to list roles: $(gql_err "$roles")"
    return 1
  fi
  ADMIN_ROLE_ID=$(jq -r --arg n "$LAB_ADMIN_ROLE" \
    '[.data.actor.organization.authorizationManagement.roles.roles[]? | select(.name == $n or .displayName == $n)] | first | .id // empty' <<<"$roles")
  RO_ROLE_ID=$(jq -r --arg n "$LAB_READONLY_ROLE" \
    '[.data.actor.organization.authorizationManagement.roles.roles[]? | select(.name == $n or .displayName == $n)] | first | .id // empty' <<<"$roles")
  if [[ -z "$ADMIN_ROLE_ID" ]]; then print_err "Role '${LAB_ADMIN_ROLE}' not found"; return 1; fi
  if [[ -z "$RO_ROLE_ID" ]]; then print_err "Role '${LAB_READONLY_ROLE}' not found"; return 1; fi
  echo "  Admin group '${LAB_ADMIN_GROUP_NAME}': ${ADMIN_GROUP_ID}  |  roles: ${LAB_ADMIN_ROLE}=${ADMIN_ROLE_ID}, ${LAB_READONLY_ROLE}=${RO_ROLE_ID}"
}

# VERIFIED live (regionCode, 2026-10-21) (account creation).
# Sets CREATED_ACCOUNT_ID on success.
_create_account() { # _create_account <name>
  local q result err
  CREATED_ACCOUNT_ID=""
  q=$(jq -rn --arg n "$1" --arg r "$LAB_ACCOUNT_REGION" \
    '"mutation { accountManagementCreateAccount(managedAccount: {name: \"" + $n + "\", regionCode: \"" + $r + "\"}) { managedAccount { id name } } }"')
  result=$(gql_mut "$q") || return 1
  err=$(gql_err "$result")
  if [[ -n "$err" ]]; then
    if grep -qiE 'already|exist|duplicate|taken' <<<"$err"; then
      print_err "Account '$1' already exists but is not visible to this API key yet (earlier run interrupted before the admin grant propagated?). Wait a few minutes and re-run to resume. API said: $err"
    else
      print_err "Failed to create account '$1': $err"
    fi
    return 1
  fi
  CREATED_ACCOUNT_ID=$(jq -r '.data.accountManagementCreateAccount.managedAccount.id // empty' <<<"$result")
  if ! [[ "$CREATED_ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
    print_err "Account '$1' created but no numeric id in response: $(head -c 300 <<<"$result")"
    return 1
  fi
}

# _has_grant <group id> <account id> <role id> → 0 when the group already holds the role
# on the account.  A failing lookup returns 1 ("not known to be granted"); the grant call
# itself treats already-exists as success, so this stays safe.
_has_grant() {
  local grants
  grants=$(group_account_grants "$1" 2>/dev/null) || return 1
  jq -e --arg a "$2" --arg r "$3" 'any(.[]; .accountId == $a and .roleId == $r)' <<<"$grants" >/dev/null
}

# _grant_access <group id> <account id> <role id>: authorizationManagementGrantAccess with
# the values inlined (same style as setup-k8s). Already-exists errors count as success.
_grant_access() {
  local gid="$1" acct="$2" rid="$3" q result err attempt max=3
  q=$(jq -rn --arg g "$gid" --arg a "$acct" --arg r "$rid" \
    '"mutation { authorizationManagementGrantAccess(grantAccessOptions: {groupId: \"" + $g + "\", accountAccessGrants: [{accountId: " + $a + ", roleId: \"" + $r + "\"}]}) { roles { accountId roleId } } }"')
  for attempt in $(seq 1 "$max"); do
    result=$(gql_mut "$q") || return 1
    err=$(gql_err "$result")
    if [[ -z "$err" ]]; then return 0; fi
    if grep -qiE 'already|exist|duplicate' <<<"$err"; then return 0; fi
    if (( attempt < max )); then
      print_warn "  grant failed (attempt ${attempt}/${max}): ${err}; retrying in ${LAB_PROPAGATION_INTERVAL}s"
      sleep "$LAB_PROPAGATION_INTERVAL"
    else
      print_err "Grant failed after ${max} attempts: ${err}"
      return 1
    fi
  done
}

# _ensure_grant <label> <group name> <group id> <account id> <role id> <check 1|0>
# Sets GRANT_STATUS to exists | granted | would-grant.
_ensure_grant() {
  GRANT_STATUS=""
  if [[ "$6" == 1 ]] && _has_grant "$3" "$4" "$5"; then
    GRANT_STATUS="exists"
    echo "  $1 grant exists"
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    GRANT_STATUS="would-grant"
    echo "  WOULD grant $1 ($2 → account $4)"
    return 0
  fi
  echo "  Granting $1 to group '$2' on account $4..."
  _grant_access "$3" "$4" "$5" || return 1
  GRANT_STATUS="granted"
}

# Poll until the key can see the account (admin grant propagation).
_wait_visible() { # _wait_visible <account id> <name>
  local p polls="$LAB_PROPAGATION_POLLS" result
  for p in $(seq 1 "$polls"); do
    result=$(gql_query "{ actor { account(id: $1) { id name } } }")
    if [[ -z "$(gql_err "$result")" ]] && [[ -n "$(jq -r '.data.actor.account.id // empty' <<<"$result")" ]]; then
      echo "  account $1 visible (poll ${p}/${polls})"
      return 0
    fi
    echo "  waiting for account $1 to become visible (${p}/${polls})..."
    if (( p < polls )); then sleep "$LAB_PROPAGATION_INTERVAL"; fi
  done
  print_err "Account $1 ('$2') is still not visible to this API key after ${polls} polls x ${LAB_PROPAGATION_INTERVAL}s. The admin grant for group '${LAB_ADMIN_GROUP_NAME}' has not propagated (or the key's user is not in that group). Re-run 'accounts create' to resume; finished steps are skipped."
  return 1
}

# The account can be visible before the key-view capability has propagated: the first
# keySearch then fails with "You do not have permission to view license keys". Treat that
# one error as "not yet" and retry for the same window as _wait_visible; anything else fails.
# Sets LICENSE_LOOKUP_KEY (empty when the account has no key yet).
_license_key_wait() { # _license_key_wait <account id>
  local p polls="$LAB_PROPAGATION_POLLS" out rc=0
  LICENSE_LOOKUP_KEY=""
  for p in $(seq 1 "$polls"); do
    rc=0; out=$(license_key_for_account "$1" 2>&1) || rc=$?
    if (( rc == 0 )); then LICENSE_LOOKUP_KEY="$out"; return 0; fi
    if [[ "$DRY_RUN" == 1 ]] || ! grep -qi 'permission' <<<"$out"; then
      printf '%s\n' "$out" >&2; return 1
    fi
    echo "  waiting for license key permission on account $1 to propagate (${p}/${polls})..."
    if (( p < polls )); then sleep "$LAB_PROPAGATION_INTERVAL"; fi
  done
  printf '%s\n' "$out" >&2
  return 1
}

# UNVERIFIED shape: confirm via introspection (key creation).
_create_license_key() { # _create_license_key <account id>
  local q result err
  q=$(jq -rn --arg a "$1" \
    '"mutation { apiAccessCreateKeys(keys: {ingest: [{accountId: " + $a + ", ingestType: LICENSE, name: \"Lab License Key\"}]}) { createdKeys { id key } errors { message type } } }"')
  result=$(gql_mut "$q") || return 1
  err=$(gql_err "$result")
  if [[ -z "$err" ]]; then
    err=$(jq -r '(.data.apiAccessCreateKeys.errors // []) | if length > 0 then (.[0].message // "unknown error") else empty end' <<<"$result")
  fi
  if [[ -n "$err" ]]; then
    print_err "Failed to create license key for account $1: $err"
    return 1
  fi
  if [[ -z "$(jq -r '.data.apiAccessCreateKeys.createdKeys[0].key // empty' <<<"$result")" ]]; then
    print_err "License key request for account $1 returned no key"
    return 1
  fi
}

# VERIFIED live (group created, 2026-10-21) (same mutation setup-k8s uses; sets CREATED_GROUP_ID).
_create_group() { # _create_group <name>
  local result err
  CREATED_GROUP_ID=""
  result=$(gql_mut 'mutation($opts: UserManagementCreateGroup) { userManagementCreateGroup(createGroupOptions: $opts) { group { id displayName } } }' \
    "$(jq -n --arg d "$NR_AUTH_DOMAIN_ID" --arg n "$1" '{opts: {authenticationDomainId: $d, displayName: $n}}')") || return 1
  err=$(gql_err "$result")
  if [[ -n "$err" ]]; then
    if grep -qiE 'already|taken' <<<"$err"; then
      # Lagging read after a previous create: reuse it.
      CREATED_GROUP_ID=$(_group_id_by_name "$1") || return 1
      [[ -n "$CREATED_GROUP_ID" ]] && return 0
    fi
    print_err "Failed to create group '$1': $err"
    return 1
  fi
  CREATED_GROUP_ID=$(jq -r '.data.userManagementCreateGroup.group.id // empty' <<<"$result")
  if [[ -z "$CREATED_GROUP_ID" ]]; then
    print_err "Group '$1' created but id missing: $(head -c 300 <<<"$result")"
    return 1
  fi
}

_print_account_summary() { # uses S_* globals
  printf '  %s  account=%s admin=%s key=%s group=%s %s=%s\n' \
    "$1" "${S_ACCT:--}" "${S_ADMIN:--}" "${S_KEY:--}" "${S_GROUP:--}" "$LAB_READONLY_ROLE" "${S_RO:--}"
}

# provision_account <name>: five idempotent steps, each skipped when already done.
provision_account() {
  local name="$1" gname id="" gid="" key
  gname="${name}${POOL_LAB_GROUP_SUFFIX}"
  S_ACCT="" S_ADMIN="" S_KEY="" S_GROUP="" S_RO=""
  print_step "$name"

  # (1) find the account by exact name, else create it
  # UNVERIFIED shape: confirm via introspection (actor.accounts listing + create below)
  id=$(account_id_by_name "$name") || return 1
  if [[ -n "$id" ]]; then
    S_ACCT="exists"
    echo "  account exists (id $id)"
  elif [[ "$DRY_RUN" == 1 ]]; then
    S_ACCT="would-create"
    echo "  WOULD create account '$name' (region ${LAB_ACCOUNT_REGION})"
    echo "  WOULD then: grant ${LAB_ADMIN_ROLE} to '${LAB_ADMIN_GROUP_NAME}', wait for visibility, create license key, create group '${gname}', grant ${LAB_READONLY_ROLE}"
    S_ADMIN="would-grant" S_KEY="would-create" S_GROUP="would-create" S_RO="would-grant"
    _print_account_summary "$name"
    return 0
  else
    echo "  Creating account '$name'..."
    _create_account "$name" || return 1
    id="$CREATED_ACCOUNT_ID"
    S_ACCT="created"
    print_ok "  created account $id"
  fi

  # (2) admin group → admin role on the account
  _ensure_grant "admin" "$LAB_ADMIN_GROUP_NAME" "$ADMIN_GROUP_ID" "$id" "$ADMIN_ROLE_ID" 1 || return 1
  S_ADMIN="$GRANT_STATUS"

  # (3) wait until the grant propagated and the key can see the account
  if [[ "$DRY_RUN" != 1 ]]; then
    _wait_visible "$id" "$name" || return 1
  fi

  # (4) ingest LICENSE key
  # VERIFIED live (keySearch lookup works) (license_key_for_account uses actor.apiAccess.keySearch)
  _license_key_wait "$id" || return 1
  key="$LICENSE_LOOKUP_KEY"
  if [[ -n "$key" ]]; then
    S_KEY="exists"
    echo "  license key exists"
  elif [[ "$DRY_RUN" == 1 ]]; then
    S_KEY="would-create"
    echo "  WOULD create ingest LICENSE key"
  else
    echo "  Creating ingest LICENSE key..."
    _create_license_key "$id" || return 1
    S_KEY="created"
  fi
  key=""

  # (5) "<name> - ReadOnly" group + learner-role grant (LAB_READONLY_ROLE)
  gid=$(_group_id_by_name "$gname") || return 1
  if [[ -n "$gid" ]]; then
    S_GROUP="exists"
    echo "  group '$gname' exists"
    _ensure_grant "$LAB_READONLY_ROLE" "$gname" "$gid" "$id" "$RO_ROLE_ID" 1 || return 1
  elif [[ "$DRY_RUN" == 1 ]]; then
    S_GROUP="would-create"
    echo "  WOULD create group '$gname'"
    S_RO="would-grant"
    echo "  WOULD grant ${LAB_READONLY_ROLE} on account $id"
    _print_account_summary "$name (id $id)"
    return 0
  else
    echo "  Creating group '$gname'..."
    _create_group "$gname" || return 1
    gid="$CREATED_GROUP_ID"
    S_GROUP="created"
    _ensure_grant "$LAB_READONLY_ROLE" "$gname" "$gid" "$id" "$RO_ROLE_ID" 0 || return 1
  fi
  S_RO="$GRANT_STATUS"

  _print_account_summary "$name (id $id)"
}

cmd_accounts_create() {
  local n="${1:-$LAB_ACCOUNT_COUNT}"
  _require_positive_int "$n" "account count" || return 1
  _validate_account_config || return 1
  _ctx || return 1
  print_step "Looking up admin group and roles"
  _load_lookup_ids || return 1

  SECONDS=0
  print_step "Provisioning ${n} sub-account(s) named '${LAB_ACCOUNT_PREFIX} NN'$([[ "$DRY_RUN" == 1 ]] && echo ' (dry run)')"
  echo "  Accounts are created one at a time; each waits for grant propagation (up to ${LAB_PROPAGATION_POLLS} x ${LAB_PROPAGATION_INTERVAL}s). Expect several minutes per new account."
  local i name failed=0 done_count=0
  for i in $(seq 1 "$n"); do
    name="${LAB_ACCOUNT_PREFIX} $(printf '%02d' "$i")"
    if provision_account "$name"; then
      done_count=$(( done_count + 1 ))
    else
      print_err "$name: provisioning did not finish (see above). Continuing with the next account."
      failed=$(( failed + 1 ))
    fi
  done

  echo ""
  echo "Processed OK: $done_count  |  Failed: $failed  |  Total runtime: ${SECONDS}s"
  if [[ "$failed" -gt 0 ]]; then
    print_warn "Re-run 'accounts create ${n}' to resume the failed accounts; finished steps are skipped."
    return 1
  fi
}

# Prints JSON array [{id,name}] of accounts named "<LAB_ACCOUNT_PREFIX> <digits>", sorted by name.
_lab_accounts() {
  local accounts
  accounts=$(fetch_accounts) || return 1
  jq -c --arg re "^${LAB_ACCOUNT_PREFIX} [0-9]+\$" '[.[] | select(.name | test($re))] | sort_by(.name)' <<<"$accounts"
}

cmd_accounts_status() {
  _validate_prefix || return 1
  _ctx || return 1
  print_step "Fetching lab accounts, groups and pool users"
  local accts groups users total=0 free=0 claimed=0
  accts=$(_lab_accounts) || return 1
  groups=$(fetch_lab_groups) || return 1
  users=$(fetch_users) || return 1

  if [[ "$(jq 'length' <<<"$accts")" -eq 0 ]]; then
    print_warn "No accounts named '${LAB_ACCOUNT_PREFIX} NN' found."
    return 0
  fi

  echo ""
  printf '%-12s %-18s %-7s %-22s %-34s %s\n' "ID" "NAME" "GROUP" "GROUP-GRANT" "CLAIMED-BY" "LICENSE-KEY"
  local acct_json id name gid claimed_by has_group key keycol grantcol grants no_grant=0
  while IFS= read -r acct_json <&3; do
    id=$(jq -r '.id' <<<"$acct_json")
    name=$(jq -r '.name' <<<"$acct_json")
    gid=$(jq -r --arg n "${name}${POOL_LAB_GROUP_SUFFIX}" '[.[] | select(.name == $n)] | first | .id // empty' <<<"$groups")
    has_group="no"
    claimed_by="-"
    if [[ -n "$gid" ]]; then
      has_group="yes"
      claimed_by=$(jq -r --arg g "$gid" \
        '[.[] | select((.groups.items // []) | map(.id) | index($g) != null) | .email] | join(", ")' <<<"$users")
      if [[ -z "$claimed_by" ]]; then claimed_by="free"; fi
    fi
    # The role the group holds on THIS account (what a claimed learner gets). NONE = learner has no access.
    grantcol="-"
    if [[ -n "$gid" ]]; then
      if grants=$(group_account_grants "$gid" 2>/dev/null); then
        grantcol=$(jq -r --arg a "$id" '[.[] | select(.accountId == $a) | (if .roleName != "" then .roleName else .roleId end)] | unique | join(",")' <<<"$grants")
        if [[ -z "$grantcol" ]]; then grantcol="NONE"; no_grant=$(( no_grant + 1 )); fi
      else
        grantcol="?"
      fi
    fi
    # UNVERIFIED shape: confirm via introspection (license_key_for_account → keySearch). Key values are never printed.
    if key=$(license_key_for_account "$id" 2>/dev/null); then
      if [[ -n "$key" ]]; then keycol="yes"; else keycol="no"; fi
    else
      keycol="?"
    fi
    key=""
    printf '%-12s %-18s %-7s %-22s %-34s %s\n' "$id" "$name" "$has_group" "$grantcol" "$claimed_by" "$keycol"
    total=$(( total + 1 ))
    if [[ "$claimed_by" == "free" ]]; then
      free=$(( free + 1 ))
    elif [[ "$has_group" == "yes" ]]; then
      claimed=$(( claimed + 1 ))
    fi
  done 3< <(jq -c '.[]' <<<"$accts")

  echo ""
  echo "Accounts: $total  |  Free: $free  |  Claimed: $claimed"
  if (( no_grant > 0 )); then
    print_warn "$no_grant group(s) hold no grant on their account: a learner claiming them gets \"no access\". Run 'accounts create' to re-grant ${LAB_READONLY_ROLE}."
  fi
}

cmd_accounts_destroy() {
  _validate_prefix || return 1
  _ctx || return 1
  print_step "Fetching lab accounts, groups and pool users"
  local accts groups users total
  accts=$(_lab_accounts) || return 1
  groups=$(fetch_lab_groups) || return 1
  users=$(fetch_users) || return 1
  total=$(jq 'length' <<<"$accts")

  if [[ "$total" -eq 0 ]]; then
    print_ok "No accounts named '${LAB_ACCOUNT_PREFIX} NN' found. Nothing to destroy."
    return 0
  fi

  echo ""
  echo "Accounts to destroy ($total):"
  jq -r '.[] | "  \(.id)  \(.name)"' <<<"$accts"
  echo ""
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "Dry run. For each account above I would: remove the members of '<name>${POOL_LAB_GROUP_SUFFIX}', delete that group, then call accountManagementCancelAccount twice."
    return 0
  fi
  _confirm_yes "This cancels $total New Relic sub-account(s) and deletes their groups." || { print_warn "Aborted."; return 0; }

  local acct_json id name gid uid result err ok failed=0 done_count=0 c
  while IFS= read -r acct_json <&3; do
    id=$(jq -r '.id' <<<"$acct_json")
    name=$(jq -r '.name' <<<"$acct_json")
    ok=1
    print_step "$name (id $id)"

    gid=$(jq -r --arg n "${name}${POOL_LAB_GROUP_SUFFIX}" '[.[] | select(.name == $n)] | first | .id // empty' <<<"$groups")
    if [[ -n "$gid" ]]; then
      while IFS= read -r uid <&4; do
        if remove_user_from_group "$uid" "$gid"; then echo "  removed member $uid"; else ok=0; fi
      done 4< <(jq -r --arg g "$gid" '.[] | select((.groups.items // []) | map(.id) | index($g) != null) | .id' <<<"$users")

      result=$(gql_mut 'mutation($opts: UserManagementDeleteGroup) { userManagementDeleteGroup(groupOptions: $opts) { group { id } } }' \
        "$(jq -n --arg id "$gid" '{opts: {id: $id}}')") || ok=0
      err=$(gql_err "$result")
      if [[ -n "$err" ]]; then
        print_warn "  could not delete group: $err"
        ok=0
      else
        echo "  group deleted"
      fi
    else
      echo "  no group found (skipping group cleanup)"
    fi

    # NR needs two cancellations to fully delete an account (mirrors cleanup-k8s).
    for c in 1 2; do
      result=$(gql_mut "mutation { accountManagementCancelAccount(id: ${id}) { id isCanceled } }") || ok=0
      err=$(gql_err "$result")
      if [[ -n "$err" ]]; then
        print_warn "  cancellation ${c}/2 failed: $err"
        ok=0
      else
        echo "  cancellation ${c}/2: $(jq -c '.data.accountManagementCancelAccount' <<<"$result")"
      fi
      if (( c == 1 )); then sleep "$LAB_CANCEL_PAUSE"; fi
    done

    if [[ "$ok" == 1 ]]; then
      print_ok "  $name destroyed"
      done_count=$(( done_count + 1 ))
    else
      print_warn "  $name: finished with errors"
      failed=$(( failed + 1 ))
    fi
  done 3< <(jq -c '.[]' <<<"$accts")

  echo ""
  echo "Destroyed: $done_count  |  With errors: $failed"
  if [[ "$failed" -gt 0 ]]; then return 1; fi
}

# accounts scrub <account id|name|--all>: lib/scrub.sh on one or every lab account.
cmd_accounts_scrub() {
  local want="$1" accts targets groups users total acct_json id name gid member want_dry="$DRY_RUN" failed=0 done_count=0
  _validate_prefix || return 1
  if [[ -z "$want" ]]; then
    print_err "Name a lab account (id or '${LAB_ACCOUNT_PREFIX} NN'), or pass --all"
    return 2
  fi
  _ctx || return 1
  accts=$(_lab_accounts) || return 1
  if [[ "$want" == "--all" ]]; then
    targets="$accts"
  else
    targets=$(jq -c --arg w "$want" '[.[] | select((.id | tostring) == $w or .name == $w)]' <<<"$accts")
  fi
  total=$(jq 'length' <<<"$targets")
  if [[ "$total" -eq 0 ]]; then
    print_err "No lab account matches '$want' (only '${LAB_ACCOUNT_PREFIX} NN' accounts can be scrubbed)"
    return 1
  fi
  groups=$(fetch_lab_groups) || return 1
  users=$(fetch_users) || return 1

  # Dry pass first, always: it is the list the confirmation is about.
  local runnable="[]"
  print_step "What would be deleted"
  while IFS= read -r acct_json <&3; do
    id=$(jq -r '.id' <<<"$acct_json")
    name=$(jq -r '.name' <<<"$acct_json")
    gid=$(jq -r --arg n "${name}${POOL_LAB_GROUP_SUFFIX}" '[.[] | select(.name == $n)] | first | .id // empty' <<<"$groups")
    member=""
    if [[ -n "$gid" ]]; then
      member=$(jq -r --arg g "$gid" '[.[] | select((.groups.items // []) | map(.id) | index($g) != null) | .email] | join(", ")' <<<"$users")
    fi
    if [[ -n "$member" && "$FORCE" != 1 ]]; then
      print_warn "$name is claimed by ${member} (a lab may be running): skipped. Pass --force to scrub it anyway."
      continue
    fi
    DRY_RUN=1 scrub_account "$id" || true
    runnable=$(jq -c --argjson a "$acct_json" '. + [$a]' <<<"$runnable")
  done 3< <(jq -c '.[]' <<<"$targets")
  DRY_RUN="$want_dry"

  total=$(jq 'length' <<<"$runnable")
  if [[ "$total" -eq 0 ]]; then
    print_warn "Nothing to scrub."
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    echo ""
    echo "Dry run: nothing was deleted."
    return 0
  fi
  echo ""
  _confirm_yes "This permanently deletes the objects listed above in $total lab account(s)." || { print_warn "Aborted."; return 0; }

  while IFS= read -r acct_json <&3; do
    id=$(jq -r '.id' <<<"$acct_json")
    print_step "$(jq -r '.name' <<<"$acct_json") (id $id)"
    if scrub_account "$id"; then done_count=$(( done_count + 1 )); else failed=$(( failed + 1 )); fi
  done 3< <(jq -c '.[]' <<<"$runnable")

  echo ""
  echo "Scrubbed: $done_count  |  With errors: $failed"
  if [[ "$failed" -gt 0 ]]; then return 1; fi
}

# ═════════════════ browser tooling (Selenium) ═════════════════
# Thin wrapper over selenium/pool_users.py. These commands talk to the New Relic web UI, not
# NerdGraph, so they need no API key. --dry-run only lists the users; no browser is started.
cmd_users_browser() { # cmd_users_browser <accept-invites|validate-passwords|reset-passwords>
  local mode="$1" py="${POOL_LAB_PYTHON:-$_SCRIPT_DIR/selenium/.venv/bin/python}" flag
  case "$mode" in
    accept-invites)     flag="--accept-invites" ;;
    validate-passwords) flag="--validate-passwords" ;;
    reset-passwords)    flag="--reset-pool-passwords" ;;
    *) print_err "internal error: unknown browser mode '$mode'"; return 2 ;;
  esac
  if [[ ! -x "$py" ]]; then
    print_err "Python venv not found at: $py"
    print_err "Set it up first:"
    echo "  cd $_SCRIPT_DIR/selenium && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    return 1
  fi
  if [[ "$mode" != "accept-invites" ]]; then _require_user_domain || return 1; fi
  export POOL_EMAIL_PREFIX POOL_USER_DOMAIN POOL_USER_COUNT NR_REGION
  local args=("$flag")
  if [[ "$HEADLESS" == 1 ]]; then args[${#args[@]}]="--headless"; fi
  if [[ "$DRY_RUN" == 1 ]]; then args[${#args[@]}]="--dry-run"; fi
  print_step "pool_users.py ${args[*]}"
  "$py" "$_SCRIPT_DIR/selenium/pool_users.py" "${args[@]}"
}

# pair claim [email] [account name]: same claim the lab runs at start-up, without Instruqt.
# With no arguments claim_pair picks a random free user + free group; with an email and an
# account name that exact pair is mapped (both must be free). Nothing is persisted: release
# with 'users free <email>'.
cmd_pair_claim() {
  local want_email="${1:-}" want_acct="${2:-}"
  _ctx || return 1
  if [[ -n "$want_email" && -z "$want_acct" ]]; then
    print_err "Give both an email and an account name, or neither (e.g. pair claim labpool+001@example.com 'INSTRUQT_LAB 01')"
    return 1
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    local users groups claimed
    users=$(fetch_users) || return 1
    groups=$(fetch_lab_groups) || return 1
    claimed=$(jq -c '[.[] | (.groups.items // [])[] | .id] | unique' <<<"$users")
    echo "  WOULD claim one of these free users:  $(jq -r '[.[] | select((.groups.items // []) | length == 0) | .email] | join(", ")' <<<"$users")"
    echo "  …with one of these free groups:       $(jq -r --argjson c "$claimed" '[.[] | select((.id as $i | $c | index($i)) == null) | .name] | join(", ")' <<<"$groups")"
    return 0
  fi

  if [[ -z "$want_email" ]]; then
    claim_pair || return 1
  else
    local users groups user group
    users=$(fetch_users) || return 1
    groups=$(fetch_lab_groups) || return 1
    user=$(jq -c --arg e "$want_email" '[.[] | select((.email | ascii_downcase) == ($e | ascii_downcase))] | first // empty' <<<"$users")
    group=$(jq -c --arg n "${want_acct}${POOL_LAB_GROUP_SUFFIX}" '[.[] | select(.name == $n)] | first // empty' <<<"$groups")
    [[ -n "$user" ]] || { print_err "No pool user '$want_email'"; return 1; }
    [[ -n "$group" ]] || { print_err "No lab group '${want_acct}${POOL_LAB_GROUP_SUFFIX}'"; return 1; }
    if [[ "$(jq '(.groups.items // []) | length' <<<"$user")" != 0 ]]; then
      print_err "'$want_email' is already in a group; free it first: provision.sh users free $want_email"; return 1
    fi
    if jq -e --arg g "$(jq -r .id <<<"$group")" 'any(.[]; (.groups.items // []) | map(.id) | index($g) != null)' <<<"$users" >/dev/null; then
      print_err "Group '${want_acct}${POOL_LAB_GROUP_SUFFIX}' already has a member; free it first: provision.sh users free"; return 1
    fi
    CLAIM_USER_ID=$(jq -r .id <<<"$user"); CLAIM_USER_EMAIL=$(jq -r .email <<<"$user")
    CLAIM_GROUP_ID=$(jq -r .id <<<"$group"); CLAIM_GROUP_NAME=$(jq -r .name <<<"$group")
    add_user_to_group "$CLAIM_USER_ID" "$CLAIM_GROUP_ID" || return 1
    print_ok "Mapped ${CLAIM_USER_EMAIL} → ${CLAIM_GROUP_NAME}"
  fi

  local acct_name="${CLAIM_GROUP_NAME%"$POOL_LAB_GROUP_SUFFIX"}" accounts n_same acct_id key
  accounts=$(fetch_accounts) || return 1
  n_same=$(jq --arg n "$acct_name" '[.[] | select(.name == $n)] | length' <<<"$accounts")
  acct_id=$(account_id_by_name "$acct_name")
  key=$(license_key_for_account "${acct_id:-0}" 2>/dev/null || true)
  echo ""
  echo "  user:        ${CLAIM_USER_EMAIL}"
  echo "  group:       ${CLAIM_GROUP_NAME}"
  echo "  account:     ${acct_name} (id ${acct_id:-NOT FOUND})"
  echo "  license key: $([[ -n "$key" ]] && echo readable || echo MISSING)"
  if [[ "$n_same" -gt 1 ]]; then
    print_warn "$n_same accounts are named '$acct_name'; the lab would pick the first. Cancel the duplicate."
  fi
  key=""
  echo ""
  echo "Release with: ./provision.sh users free ${CLAIM_USER_EMAIL}"
}

# ═════════════════════ entrypoint ═════════════════════

_parse_flags() {
  DRY_RUN=0
  ASSUME_YES=0
  HEADLESS=0
  FORCE=0
  POS=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --headless) HEADLESS=1 ;;
      --force) FORCE=1 ;;
      *) POS[${#POS[@]}]="$a" ;;
    esac
  done
}

dispatch() {
  local group="${1:-}"
  case "$group" in
    ""|-h|--help|help) usage; return 0 ;;
  esac
  shift
  _parse_flags "$@"
  local sub="${POS[0]:-}" arg="${POS[1]:-}"
  case "$group:$sub" in
    users:create)     cmd_users_create ;;
    users:status)     cmd_users_status ;;
    users:free)       cmd_users_free "$arg" ;;
    users:delete)     cmd_users_delete ;;
    users:accept-invites|users:validate-passwords|users:reset-passwords)
                      cmd_users_browser "$sub" ;;
    pair:claim)       # an unquoted account name ("INSTRUQT_LAB 02") arrives as several words: re-join them
                      cmd_pair_claim "$arg" "$(IFS=' '; echo "${POS[*]:2}")" ;;
    accounts:create)  cmd_accounts_create "$arg" ;;
    accounts:status)  cmd_accounts_status ;;
    accounts:scrub)   # an unquoted account name ("INSTRUQT_LAB 02") arrives as several words: re-join them
                      cmd_accounts_scrub "$(IFS=' '; echo "${POS[*]:1}")" ;;
    accounts:destroy) cmd_accounts_destroy ;;
    *)
      print_err "Unknown command: '${group}${sub:+ $sub}'"
      usage >&2
      return 2
      ;;
  esac
}

_preflight() {
  local tool
  for tool in jq curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      print_err "$tool is required but not installed."
      return 1
    fi
  done
  if [[ -z "${NEW_RELIC_API_KEY:-}" ]] && ! command -v newrelic >/dev/null 2>&1; then
    print_err "NEW_RELIC_API_KEY is not set and the newrelic CLI is not installed. Export a User API key first."
    return 1
  fi
}

main() {
  case "${1:-}" in
    ""|-h|--help|help) usage; return 0 ;;
  esac
  # Browser tooling uses the web UI, so it needs neither jq/curl nor an API key.
  case "${1:-}:${2:-}" in
    users:accept-invites|users:validate-passwords|users:reset-passwords)
      dispatch "$@"; return ;;
  esac
  _preflight || return 1
  dispatch "$@"
}

if [[ "$_PROVISION_MAIN" == 1 ]]; then
  main "$@"
fi
