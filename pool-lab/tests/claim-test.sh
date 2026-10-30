#!/usr/bin/env bash
# ─────────────────────────────────────────────
# Offline test for lib/claim.sh. No network, no New Relic calls.
# `gql` is replaced by an in-memory (JSON file) NerdGraph stub, so the real fetch_users,
# fetch_lab_groups, add/remove membership and claim_pair code paths all run.
# Usage: ./tests/claim-test.sh
# ─────────────────────────────────────────────
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HERE/../lib/common.sh"
# shellcheck source=../lib/claim.sh
source "$_HERE/../lib/claim.sh"

POOL_EMAIL_PREFIX="labpool+"
LAB_ACCOUNT_PREFIX="LAB"
NR_ORG_ID="org-1"
NR_AUTH_DOMAIN_ID="dom-1"
export LAB_CLAIM_JITTER_MAX=0 LAB_VERIFY_SLEEP=0

STATE="$(mktemp)"
trap 'rm -f "$STATE"' EXIT
INTERFERE="none"   # none | user | group  — concurrent claim injected after our first add
INTERFERE_PERSIST=0 # 1 = inject on every add instead of once

# ── In-memory NerdGraph stub ───────────────────
# State: {"users":[{id,email,name,groups:[gid..]}], "groups":[{id,name}]}
gql() {
  local q v
  q=$(jq -r '.query' <<<"$1")
  v=$(jq -c '.variables' <<<"$1")

  if [[ "$q" == *"AddUsersToGroups"* ]]; then
    local gid uid
    gid=$(jq -r '.opts.groupIds[0]' <<<"$v"); uid=$(jq -r '.opts.userIds[0]' <<<"$v")
    _state_add "$uid" "$gid"
    # gql runs in a $(...) subshell, so "already interfered" must live in a file, not a variable.
    if [[ "$INTERFERE" != "none" ]] && { [[ "${INTERFERE_PERSIST:-0}" == 1 ]] || [[ ! -f "$STATE.done" ]]; }; then
      touch "$STATE.done"
      if [[ "$INTERFERE" == "user" ]]; then
        # another lab grabbed the same user into a different (extra) group
        _state_add "$uid" "g-other"
      else
        # another lab grabbed a different free pool user into the same group
        local other
        other=$(jq -r --arg uid "$uid" \
          '[.users[] | select(.id != $uid and (.email | startswith("labpool+")) and (.groups|length)==0)] | .[0].id // empty' "$STATE")
        [[ -n "$other" ]] && _state_add "$other" "$gid"
      fi
    fi
    echo '{"data":{"userManagementAddUsersToGroups":{"groups":[]}}}'
  elif [[ "$q" == *"RemoveUsersFromGroups"* ]]; then
    local gid uid
    gid=$(jq -r '.opts.groupIds[0]' <<<"$v"); uid=$(jq -r '.opts.userIds[0]' <<<"$v")
    jq --arg uid "$uid" --arg gid "$gid" \
      '.users |= map(if .id == $uid then .groups -= [$gid] else . end)' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    echo '{"data":{"userManagementRemoveUsersFromGroups":{"groups":[]}}}'
  elif [[ "$q" == *"users(filter"* ]]; then
    _page "$q" "$v" users
  elif [[ "$q" == *"groups(filter"* ]]; then
    _page "$q" "$v" groups
  else
    echo '{"errors":[{"message":"stub: unhandled query"}]}'
  fi
}

# Paginated like NerdGraph: PAGE_SIZE rows per page, cursor = numeric offset.
# Like the real API (and unlike a lenient stub), it rejects a query whose use of the $cursor
# variable does not match the variables sent: that is exactly the bug a null-cursor-only stub hid.
_page() { # _page <query> <variables-json> <users|groups>
  local q="$1" v="$2" kind="$3" cursor all
  cursor=$(jq -r '.cursor // empty' <<<"$v")
  if { [[ "$q" == *'$cursor'* ]] && [[ -z "$cursor" ]]; } || { [[ "$q" != *'$cursor'* ]] && [[ -n "$cursor" ]]; }; then
    echo '{"errors":[{"message":"stub: $cursor used in the query but not supplied as a variable (or vice versa)"}]}'
    return 0
  fi
  if [[ "$kind" == users ]]; then
    all=$(jq -c '[.users[] | {id, email, name, groups:{items:(.groups | map({id:., name:.}))}}]' "$STATE")
  else
    all=$(jq -c '.groups' "$STATE")
  fi
  jq -nc --argjson all "$all" --argjson off "${cursor:-0}" --argjson size "${PAGE_SIZE:-1000}" --arg kind "$kind" \
    '{data:{customerAdministration:{($kind):{
        items: $all[$off:$off+$size],
        nextCursor: (if $off+$size < ($all|length) then (($off+$size)|tostring) else null end)}}}}'
}

_state_add() { # _state_add <uid> <gid>
  jq --arg uid "$1" --arg gid "$2" \
    '.users |= map(if .id == $uid then .groups = ((.groups + [$gid]) | unique) else . end)' "$STATE" > "$STATE.tmp" \
    && mv "$STATE.tmp" "$STATE"
}

# Fixture: <users> pool users, <groups> lab groups, plus one non-pool user and two non-lab
# groups that must never be claimed ("g-nonlab", and "g-other" which user-collision injection uses).
seed() { # seed <users> <groups>
  local u g
  u=$(jq -nc --argjson n "$1" '[range(1; $n+1) | {id:("u\(.)"), email:("labpool+\(.)@example.test"), name:("Lab User \(.)"), groups:[]}]
        + [{id:"u-outsider", email:"someone@example.test", name:"Outsider", groups:[]}]')
  g=$(jq -nc --argjson n "$2" '[range(1; $n+1) | {id:("g\(.)"), name:("LAB \(. | tostring | if length<2 then "0"+. else . end) - ReadOnly")}]
        + [{id:"g-nonlab", name:"Some Other Group"}, {id:"g-other", name:"Foreign Team Group"}]')
  jq -nc --argjson u "$u" --argjson g "$g" '{users:$u, groups:$g}' > "$STATE"
  rm -f "$STATE.done"
  INTERFERE_PERSIST=0
}

# ── Tiny assertion helpers ─────────────────────
PASS=0; FAIL=0
check() { # check <description> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then PASS=$(( PASS + 1 )); echo "  ✔ $1"; else FAIL=$(( FAIL + 1 )); echo "  ✖ $1"; fi
}
user_group_count() { jq --arg id "$1" '[.users[] | select(.id == $id)] | .[0].groups | length' "$STATE"; }
group_member_count() { jq --arg id "$1" '[.users[] | select(.groups | index($id) != null)] | length' "$STATE"; }

# ── Cases ──────────────────────────────────────
echo "case 1: clean claim"
seed 3 3; INTERFERE=none
claim_pair >/dev/null; rc=$?
check "returns 0" $rc
check "user is in exactly one group" "$([[ "$(user_group_count "$CLAIM_USER_ID")" == 1 ]]; echo $?)"
check "group has exactly one member" "$([[ "$(group_member_count "$CLAIM_GROUP_ID")" == 1 ]]; echo $?)"
check "non-pool user and non-lab groups untouched" "$([[ "$CLAIM_USER_ID" != u-outsider && "$CLAIM_GROUP_ID" != g-nonlab && "$CLAIM_GROUP_ID" != g-other ]]; echo $?)"

echo "case 2: user-side collision (another lab grabs our user), recovers"
seed 3 3; INTERFERE=user
claim_pair >/dev/null; rc=$?
check "returns 0" $rc
check "claimed user is in exactly one group" "$([[ "$(user_group_count "$CLAIM_USER_ID")" == 1 ]]; echo $?)"
check "claimed group has exactly one member" "$([[ "$(group_member_count "$CLAIM_GROUP_ID")" == 1 ]]; echo $?)"
check "the contested user was not kept (it still belongs to the other lab)" "$([[ "$(user_group_count "$CLAIM_USER_ID")" == 1 && "$CLAIM_USER_ID" != "$(jq -r '[.users[]|select(.groups|index("g-other")!=null)][0].id' "$STATE")" ]]; echo $?)"

echo "case 3: group-side collision (another lab grabs a different user into our group), recovers"
seed 3 3; INTERFERE=group
claim_pair >/dev/null; rc=$?
check "returns 0" $rc
check "claimed group has exactly one member" "$([[ "$(group_member_count "$CLAIM_GROUP_ID")" == 1 ]]; echo $?)"
check "claimed user is in exactly one group" "$([[ "$(user_group_count "$CLAIM_USER_ID")" == 1 ]]; echo $?)"

echo "case 4: no free pool users"
seed 0 3; INTERFERE=none
claim_pair >/dev/null 2>&1; rc=$?
check "returns non-zero" "$([[ $rc -ne 0 ]]; echo $?)"

echo "case 5: no free lab groups"
seed 3 1; INTERFERE=none
# the only lab group (g1) is already claimed by u1, so none are free
_state_add u1 g1
claim_pair >/dev/null 2>&1; rc=$?
check "returns non-zero" "$([[ $rc -ne 0 ]]; echo $?)"

echo "case 6: every attempt collides, gives up after LAB_CLAIM_MAX_ATTEMPTS"
seed 6 6; INTERFERE=group; INTERFERE_PERSIST=1
out=$(LAB_CLAIM_MAX_ATTEMPTS=3 claim_pair 2>&1); rc=$?
check "returns non-zero" "$([[ $rc -ne 0 ]]; echo $?)"
check "fails for the collision reason, not for lack of free users/groups" "$(grep -q 'after 3 attempts' <<<"$out"; echo $?)"
# 3 attempts → 3 injected "other lab" users remain; every membership we added was rolled back.
check "rolled back all of our own memberships (only the 3 injected users remain placed)" "$([[ "$(jq '[.users[] | select((.email|startswith("labpool+")) and (.groups|length)>0)] | length' "$STATE")" == 3 ]]; echo $?)"
INTERFERE=none; INTERFERE_PERSIST=0

echo "case 7: pagination (page size 2) returns every pool user and every lab group"
seed 5 5; INTERFERE=none; PAGE_SIZE=2
users_json=$(fetch_users); rc_u=$?
groups_json=$(fetch_lab_groups); rc_g=$?
check "fetch_users succeeds across 3 pages" $rc_u
check "fetch_users returned all 5 pool users (outsider filtered out)" "$([[ "$(jq length <<<"$users_json")" == 5 ]]; echo $?)"
check "fetch_lab_groups succeeds across pages and returned exactly the 5 lab groups" "$([[ $rc_g -eq 0 && "$(jq length <<<"$groups_json")" == 5 ]]; echo $?)"
claim_pair >/dev/null; rc=$?
check "claim_pair works end to end with paginated reads" $rc
PAGE_SIZE=1000

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
