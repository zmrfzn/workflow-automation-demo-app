#!/usr/bin/env bash
# ─────────────────────────────────────────────
# pool-lab teardown: runs inside the Instruqt VM at lab end (track script cleanup-<vm>).
# Scrubs the lab account (lib/scrub.sh: alerts, workflows, destinations, entities, the learner's
# user keys), then removes the claimed pool user from its lab group. Groups and sub-accounts are
# pre-made by the instructor and are reused, so they are never deleted here.
# Non-fatal on purpose (like cleanup-k8s): every problem is a warning, exit is always 0.
# Needs the same LAB_NR_API_KEY_SECRET indirection as bootstrap.sh.
#
# Test seam: if POOL_LAB_TEST_STUB points at a file, it is sourced right after the libs so a
# test can override gql/sleep. Never set it in a real track.
# ─────────────────────────────────────────────
set -uo pipefail

_POOL_LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # pool-lab:inline
source "$_POOL_LAB_DIR/lib/common.sh" # pool-lab:inline
source "$_POOL_LAB_DIR/lib/claim.sh" # pool-lab:inline
source "$_POOL_LAB_DIR/lib/scrub.sh" # pool-lab:inline

if [[ -n "${POOL_LAB_TEST_STUB:-}" ]]; then
  # shellcheck disable=SC1090
  source "$POOL_LAB_TEST_STUB"
fi

echo ""
echo "=== [$(date +%H:%M:%S)] pool-lab teardown ==="

if ! command -v jq >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  { apt-get update -qq && apt-get install -y -qq jq curl; } >/dev/null 2>&1 || true
fi
if ! command -v jq >/dev/null 2>&1; then
  print_warn "jq is not available, cannot release the pool user"
  exit 0
fi

POOL_USER_ID="$(agent_var_get POOL_USER_ID 2>/dev/null || true)"
POOL_GROUP_ID="$(agent_var_get POOL_GROUP_ID 2>/dev/null || true)"
if [[ -z "$POOL_USER_ID" || -z "$POOL_GROUP_ID" ]]; then
  echo "  POOL_USER_ID/POOL_GROUP_ID not set, nothing to release"
  exit 0
fi

if [[ -z "${LAB_NR_API_KEY_SECRET:-}" ]]; then
  print_warn "LAB_NR_API_KEY_SECRET is not set, cannot release ${POOL_USER_ID} from ${POOL_GROUP_ID}"
  exit 0
fi
_key_value="${!LAB_NR_API_KEY_SECRET:-}"
if [[ -z "$_key_value" ]]; then
  print_warn "Env var '${LAB_NR_API_KEY_SECRET}' is empty, cannot release ${POOL_USER_ID} from ${POOL_GROUP_ID}"
  exit 0
fi
export NEW_RELIC_API_KEY="$_key_value"
unset _key_value

# Lab accounts are reused: delete everything this learner created before releasing the user,
# so the next learner who claims the account starts from blank (lib/scrub.sh).
ACCOUNT_ID="$(agent_var_get NEW_RELIC_ACCOUNT_ID 2>/dev/null || true)"
if [[ "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
  if scrub_account "$ACCOUNT_ID"; then
    print_ok "Account ${ACCOUNT_ID} scrubbed"
  else
    print_warn "Account ${ACCOUNT_ID} was not fully scrubbed; before the next lab run: ./provision.sh accounts scrub ${ACCOUNT_ID}"
  fi
else
  print_warn "NEW_RELIC_ACCOUNT_ID not set, cannot scrub the lab account"
fi

if remove_user_from_group "$POOL_USER_ID" "$POOL_GROUP_ID"; then
  print_ok "Released pool user ${POOL_USER_ID} from group ${POOL_GROUP_ID} (group and account kept for reuse)"
else
  print_warn "Could not release pool user ${POOL_USER_ID} from group ${POOL_GROUP_ID}; run 'provision.sh users free' to free it"
fi
# All Product Admin can delete license keys; the account is reused, so check the next lab still has one.
if [[ "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
  if _k=$(license_key_for_account "$ACCOUNT_ID" 2>/dev/null); then
    if [[ -n "$_k" ]]; then
      echo "  account ${ACCOUNT_ID} still has its ingest license key"
    else
      print_warn "Account ${ACCOUNT_ID} has NO ingest license key any more (deleted during the lab?). The next lab on it will fail: run 'provision.sh accounts create' to recreate it."
    fi
  else
    print_warn "Could not check the license key of account ${ACCOUNT_ID}"
  fi
  _k=""
fi
exit 0
