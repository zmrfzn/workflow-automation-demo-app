#!/usr/bin/env bash
# ─────────────────────────────────────────────
# pool-lab bootstrap: runs inside the Instruqt VM at lab start (track script setup-<vm>).
# Claims a free pre-made pool user + lab group, resolves the group's sub-account and its
# ingest license key, and persists everything as Instruqt agent variables.
# No terraform, no repo clone, no baked helpers: curl + jq only.
#
# Env contract:
#   LAB_NR_API_KEY_SECRET    NAME of the env var that holds the NerdGraph user key (required)
#   LAB_USER_PASSWORD_SECRET NAME of the env var that holds the shared pool user password (optional, warns)
#   POOL_EMAIL_PREFIX, LAB_ACCOUNT_PREFIX, POOL_AUTH_DOMAIN_NAME, NR_REGION   as in lib/common.sh
#
# Built into a single self-contained file by build-lab-scripts.sh: the three lines
# carrying the inline marker are removed from the built file because the libs are
# concatenated in front of this body.
#
# Test seam: if POOL_LAB_TEST_STUB points at a file, it is sourced right after the libs so a
# test can override gql/sleep. Never set it in a real track.
# ─────────────────────────────────────────────
set -euo pipefail

_POOL_LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # pool-lab:inline
source "$_POOL_LAB_DIR/lib/common.sh" # pool-lab:inline
source "$_POOL_LAB_DIR/lib/claim.sh" # pool-lab:inline

if [[ -n "${POOL_LAB_TEST_STUB:-}" ]]; then
  # shellcheck disable=SC1090
  source "$POOL_LAB_TEST_STUB"
fi

CURRENT_STEP="startup"
CLAIM_HELD=0     # 1 only while a freshly made claim has not yet been fully persisted
PAIR_REUSED=0

section() {
  CURRENT_STEP="$*"
  echo ""
  echo "=== [$(date +%H:%M:%S)] $* ==="
}

# Non-fatal best-effort release of a half-finished claim so the pair is not leaked.
_release_claim() {
  if [[ "$CLAIM_HELD" == 1 && -n "${CLAIM_USER_ID:-}" && -n "${CLAIM_GROUP_ID:-}" ]]; then
    echo "  ↩ Releasing claim ${CLAIM_USER_EMAIL:-$CLAIM_USER_ID} → ${CLAIM_GROUP_NAME:-$CLAIM_GROUP_ID} after failure..."
    remove_user_from_group "$CLAIM_USER_ID" "$CLAIM_GROUP_ID" \
      || print_warn "Could not release the claim; run 'provision.sh users free' to free the pair"
    CLAIM_HELD=0
  fi
}

_on_err() {
  local rc=$? line="${BASH_LINENO[0]:-?}"
  print_err "bootstrap failed during step '${CURRENT_STEP}' (line ${line}, exit ${rc})"
}
_on_exit() {
  local rc=$?
  if (( rc != 0 )); then _release_claim; fi
  return 0
}
trap _on_err ERR
trap _on_exit EXIT

die() {
  print_err "$*"
  exit 1
}

# ── (a) host bootstrap ────────────────────────
section "Waiting for Instruqt host bootstrap"
if [[ -d /opt/instruqt/bootstrap ]]; then
  _bs_start=$(date +%s)
  until [[ -f /opt/instruqt/bootstrap/host-bootstrap-completed ]]; do
    if (( $(date +%s) - _bs_start > 300 )); then
      ls -la /opt/instruqt/bootstrap/ 2>/dev/null || true
      die "Host bootstrap did not complete within 300s"
    fi
    sleep 2
  done
  echo "  host bootstrap complete"
else
  echo "  /opt/instruqt/bootstrap not present, skipping wait"
fi

# ── (b) dependencies ──────────────────────────
section "Checking dependencies"
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  installing jq/curl via apt-get..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq jq curl >/dev/null
fi
command -v jq >/dev/null 2>&1 || die "jq is not available and could not be installed"
command -v curl >/dev/null 2>&1 || die "curl is not available and could not be installed"
echo "  jq and curl present"

# ── (c) secrets ───────────────────────────────
section "Validating secrets"
[[ -n "${LAB_NR_API_KEY_SECRET:-}" ]] \
  || die "LAB_NR_API_KEY_SECRET is not set (it must hold the NAME of the env var that contains the NerdGraph user key)"
_key_value="${!LAB_NR_API_KEY_SECRET:-}"
[[ -n "$_key_value" ]] \
  || die "Env var '${LAB_NR_API_KEY_SECRET}' (named by LAB_NR_API_KEY_SECRET) is empty or unset; declare it under secrets: in config.yml"
export NEW_RELIC_API_KEY="$_key_value"
unset _key_value

LAB_USER_PASSWORD=""
if [[ -n "${LAB_USER_PASSWORD_SECRET:-}" ]]; then
  LAB_USER_PASSWORD="${!LAB_USER_PASSWORD_SECRET:-}"
fi
if [[ -z "$LAB_USER_PASSWORD" ]]; then
  print_warn "No shared pool user password available (LAB_USER_PASSWORD_SECRET unset or empty); learners will not get a password in the lab"
fi
echo "  NerdGraph key present"

# ── (d) org context ───────────────────────────
section "Resolving New Relic org context"
resolve_context
echo "  org=${NR_ORG_ID} auth-domain=${NR_AUTH_DOMAIN_ID}"

# ── (e) user/group pair ───────────────────────
# resolve_pair is the single seam for choosing which pool user belongs to which lab group.
# A later LAB_MAPPING_MODE=manifest can replace this function with a lookup in a pre-made
# user-to-account manifest. Everything after it only needs CLAIM_USER_* and CLAIM_GROUP_*.
resolve_pair() {
  PAIR_REUSED=0
  local prev_uid prev_gid users groups hit
  prev_uid=$(agent_var_get POOL_USER_ID 2>/dev/null || true)
  prev_gid=$(agent_var_get POOL_GROUP_ID 2>/dev/null || true)
  if [[ -n "$prev_uid" && -n "$prev_gid" ]]; then
    users=$(fetch_users) || return 1
    groups=$(fetch_lab_groups) || return 1
    hit=$(jq -c --arg u "$prev_uid" --arg g "$prev_gid" --argjson groups "$groups" \
      '[.[] | select(.id == $u) | select((.groups.items // []) | map(.id) | index($g) != null)] | first
       | if . == null then empty else {user: ., group: ([$groups[] | select(.id == $g)] | first)} end' <<<"$users")
    if [[ -n "$hit" ]] && jq -e '.group != null' >/dev/null <<<"$hit"; then
      CLAIM_USER_ID=$(jq -r '.user.id' <<<"$hit")
      CLAIM_USER_EMAIL=$(jq -r '.user.email' <<<"$hit")
      CLAIM_USER_NAME=$(jq -r '.user.name' <<<"$hit")
      CLAIM_GROUP_ID=$(jq -r '.group.id' <<<"$hit")
      CLAIM_GROUP_NAME=$(jq -r '.group.name' <<<"$hit")
      PAIR_REUSED=1
      print_ok "Re-run: reusing existing claim ${CLAIM_USER_EMAIL} → ${CLAIM_GROUP_NAME}"
      return 0
    fi
    echo "  Previous claim (${prev_uid} / ${prev_gid}) is no longer in place, claiming a new pair"
  fi
  claim_pair
}

section "Claiming a pool user and lab group"
resolve_pair
if [[ "$PAIR_REUSED" == 0 ]]; then
  CLAIM_HELD=1
fi

# ── (f) account + license key ─────────────────
section "Resolving sub-account and license key"
ACCOUNT_NAME="${CLAIM_GROUP_NAME%"$POOL_LAB_GROUP_SUFFIX"}"
if [[ "$ACCOUNT_NAME" == "$CLAIM_GROUP_NAME" || -z "$ACCOUNT_NAME" ]]; then
  die "Group '${CLAIM_GROUP_NAME}' does not end with '${POOL_LAB_GROUP_SUFFIX}', cannot derive the account name"
fi
ACCOUNT_ID=$(account_id_by_name "$ACCOUNT_NAME")
[[ -n "$ACCOUNT_ID" ]] \
  || die "No account named '${ACCOUNT_NAME}' is visible to the API key (group '${CLAIM_GROUP_NAME}' has no matching sub-account)"
GROUP_GRANTS=$(group_account_grants "$CLAIM_GROUP_ID") \
  || die "Could not read the grants of group '${CLAIM_GROUP_NAME}'"
GRANT_ROLES=$(jq -r --arg a "$ACCOUNT_ID" '[.[] | select(.accountId == $a) | (if .roleName != "" then .roleName else .roleId end)] | unique | join(", ")' <<<"$GROUP_GRANTS")
[[ -n "$GRANT_ROLES" ]] \
  || die "Group '${CLAIM_GROUP_NAME}' holds no grant on account ${ACCOUNT_ID}, so the learner would get 'no access'. The instructor must run 'provision.sh accounts create' to re-grant it."
if [[ "$(jq --arg a "$ACCOUNT_ID" '[.[] | select(.accountId != $a)] | length' <<<"$GROUP_GRANTS")" != 0 ]]; then
  print_warn "Group '${CLAIM_GROUP_NAME}' also holds grants on other accounts: the learner will see more than one account"
fi
echo "  learner role on account ${ACCOUNT_ID}: ${GRANT_ROLES}"
LICENSE_KEY=$(license_key_for_account "$ACCOUNT_ID")
[[ -n "$LICENSE_KEY" ]] \
  || die "No ingest license key found for account '${ACCOUNT_NAME}' (${ACCOUNT_ID}). The instructor must run 'provision.sh accounts create' for it."
echo "  account='${ACCOUNT_NAME}' id=${ACCOUNT_ID} license key found"

# ── (g) persist agent variables ───────────────
section "Persisting agent variables"
agent_var_set NEW_RELIC_ACCOUNT_ID "$ACCOUNT_ID"
agent_var_set NEW_RELIC_LICENSE_KEY "$LICENSE_KEY"
agent_var_set ACCOUNT_NAME "$ACCOUNT_NAME"
agent_var_set NR_ORG_ID "$NR_ORG_ID"
agent_var_set POOL_USER_ID "$CLAIM_USER_ID"
agent_var_set POOL_USER_EMAIL "$CLAIM_USER_EMAIL"
agent_var_set POOL_USER_NAME "$CLAIM_USER_NAME"
agent_var_set USER_EMAIL "$CLAIM_USER_EMAIL"   # MARS-compatible names
agent_var_set USER_NAME "$CLAIM_USER_NAME"
agent_var_set POOL_GROUP_ID "$CLAIM_GROUP_ID"
agent_var_set LAB_USER_PASSWORD "$LAB_USER_PASSWORD"

CLAIM_HELD=0  # everything persisted: from here on the claim is the lab's to keep
trap - ERR
print_ok "pool-lab ready: user=${CLAIM_USER_EMAIL} account='${ACCOUNT_NAME}' (id ${ACCOUNT_ID}) group='${CLAIM_GROUP_NAME}'"
