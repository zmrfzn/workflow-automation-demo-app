#!/usr/bin/env bash
# ─────────────────────────────────────────────
# Offline test for provision.sh. No network, no New Relic calls.
# `gql` is replaced by an in-memory (JSON file) NerdGraph stub that also appends every
# mutation (and every account-visibility poll) to a log, so the tests can assert the exact
# mutation sequence. provision.sh is sourced (main is not run) and each command runs in a
# subshell with `set -euo pipefail`, like the real script.
# Usage: ./tests/provision-test.sh
# ─────────────────────────────────────────────
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../provision.sh
source "$_HERE/../provision.sh"

POOL_EMAIL_PREFIX="labpool+"
POOL_USER_DOMAIN="example.test"
POOL_USER_COUNT=3
LAB_ACCOUNT_PREFIX="LAB"
export LAB_PROPAGATION_INTERVAL=0 LAB_PROPAGATION_POLLS=10 LAB_CANCEL_PAUSE=0
LAB_PROPAGATION_INTERVAL=0 LAB_PROPAGATION_POLLS=10 LAB_CANCEL_PAUSE=0
export STUB_POLL_DELAY=2   # a new account becomes visible on the 3rd poll after its admin grant

STATE="$(mktemp)"
LOG="$(mktemp)"
OUT="$(mktemp)"
trap 'rm -f "$STATE" "$STATE.tmp" "$LOG" "$OUT"' EXIT

# ── In-memory NerdGraph stub ───────────────────
# State: {"seq":N, "users":[{id,email,name,groups:[gid]}], "groups":[{id,name,roles:[{roleId,accountId}]}],
#         "accounts":[{id,name,granted,visible,polls_left}], "keys":[{accountId,key}]}
_st() { # _st <jq filter> [jq options...]  → update the state file in place
  local f="$1"; shift
  jq "$@" "$f" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
_next_id() { local n; n=$(jq '.seq + 1' "$STATE"); _st '.seq = $n' --argjson n "$n"; echo "$n"; }
_log() { echo "$1" >> "$LOG"; }

gql() {
  local q v
  q=$(jq -r '.query' <<<"$1")
  v=$(jq -c '.variables // {}' <<<"$1")

  case "$q" in
    *"authorizationManagement { roles"*)
      echo '{"data":{"actor":{"organization":{"authorizationManagement":{"roles":{"roles":[{"id":"r-admin","name":"all_product_admin","displayName":"All product admin","type":"t"},{"id":"r-ro","name":"read_only","displayName":"Read only","type":"t"}]}}}}}}' ;;
    *"organization { id }"*)
      echo '{"data":{"actor":{"organization":{"id":"org-1"}}}}' ;;
    *"authenticationDomains(filter"*)
      echo '{"data":{"customerAdministration":{"authenticationDomains":{"items":[{"id":"dom-1","name":"Default"}]}}}}' ;;

    *"userManagementCreateUser"*)
      local email
      email=$(jq -r '.opts.email' <<<"$v")
      if jq -e --arg e "$email" 'any(.users[]; .email == $e)' "$STATE" >/dev/null; then
        echo '{"errors":[{"message":"User already exists"}]}'
      else
        _log "M:createUser:$email"
        _st '.users += [{id:("u-"+$e), email:$e, name:$e, groups:[]}]' --arg e "$email"
        echo '{"data":{"userManagementCreateUser":{"createdUser":{"id":"u-new"}}}}'
      fi ;;
    *"userManagementAddUsersToGroups"*)
      local gid uid
      gid=$(jq -r '.opts.groupIds[0]' <<<"$v"); uid=$(jq -r '.opts.userIds[0]' <<<"$v")
      _log "M:addToGroup:$uid:$gid"
      _st '.users |= map(if .id == $u then .groups = ((.groups + [$g]) | unique) else . end)' --arg u "$uid" --arg g "$gid"
      echo '{"data":{"userManagementAddUsersToGroups":{"groups":[]}}}' ;;
    *"userManagementRemoveUsersFromGroups"*)
      local gid uid
      gid=$(jq -r '.opts.groupIds[0]' <<<"$v"); uid=$(jq -r '.opts.userIds[0]' <<<"$v")
      _log "M:removeFromGroup:$uid:$gid"
      _st '.users |= map(if .id == $u then .groups -= [$g] else . end)' --arg u "$uid" --arg g "$gid"
      echo '{"data":{"userManagementRemoveUsersFromGroups":{"groups":[]}}}' ;;
    *"userManagementDeleteGroup"*)
      local gid
      gid=$(jq -r '.opts.id' <<<"$v")
      _log "M:deleteGroup:$gid"
      _st '.groups |= map(select(.id != $g))' --arg g "$gid"
      echo '{"data":{"userManagementDeleteGroup":{"group":{"id":"x"}}}}' ;;
    *"userManagementDeleteUser"*)
      local uid
      uid=$(jq -r '.opts.id' <<<"$v")
      _log "M:deleteUser:$uid"
      _st '.users |= map(select(.id != $u))' --arg u "$uid"
      echo '{"data":{"userManagementDeleteUser":{"deletedUser":{"id":"x"}}}}' ;;
    *"userManagementCreateGroup"*)
      local name id
      name=$(jq -r '.opts.displayName' <<<"$v"); id="g-$(_next_id)"
      _log "M:createGroup:$name"
      _st '.groups += [{id:$id, name:$n, roles:[]}]' --arg id "$id" --arg n "$name"
      jq -nc --arg id "$id" --arg n "$name" '{data:{userManagementCreateGroup:{group:{id:$id, displayName:$n}}}}' ;;

    *"accountManagementCreateAccount"*)
      local name id
      # Real API: the region field is regionCode (plain "region" and "region_code" are both rejected).
      if [[ "$q" != *'regionCode: "'* || "$q" == *', region: "'* || "$q" == *'region_code'* ]]; then
        echo '{"errors":[{"message":"Argument \"managedAccount\" has invalid value: In field \"region\": Unknown field."}]}'; return 0
      fi
      name=$(sed -E 's/.*managedAccount: \{name: "([^"]*)".*/\1/' <<<"$q"); id=$(_next_id)
      _log "M:createAccount:$name"
      _st '.accounts += [{id:$id, name:$n, granted:false, visible:false, polls_left:($p|tonumber)}]' \
        --argjson id "$id" --arg n "$name" --arg p "${STUB_POLL_DELAY:-2}"
      jq -nc --argjson id "$id" --arg n "$name" '{data:{accountManagementCreateAccount:{managedAccount:{id:$id, name:$n}}}}' ;;
    *"accountManagementCancelAccount"*)
      local id
      id=$(sed -E 's/.*id: ([0-9]+).*/\1/' <<<"$q")
      _log "M:cancel:$id"
      echo '{"data":{"accountManagementCancelAccount":{"id":"'"$id"'","isCanceled":true}}}' ;;
    *"authorizationManagementGrantAccess"*)
      local gid acct rid gname
      gid=$(sed -E 's/.*groupId: "([^"]*)".*/\1/' <<<"$q")
      acct=$(sed -E 's/.*accountId: ([0-9]+),.*/\1/' <<<"$q")
      rid=$(sed -E 's/.*roleId: "([^"]*)".*/\1/' <<<"$q")
      gname=$(jq -r --arg g "$gid" '[.groups[] | select(.id == $g)] | first | .name' "$STATE")
      _log "M:grant:$gname:$rid:$acct"
      _st '.groups |= map(if .id == $g then .roles = ((.roles + [{roleId:$r, accountId:($a|tonumber)}]) | unique) else . end)
           | if $n == "Admin" then .accounts |= map(if (.id|tostring) == $a then .granted = true else . end) else . end' \
        --arg g "$gid" --arg r "$rid" --arg a "$acct" --arg n "$gname"
      echo '{"data":{"authorizationManagementGrantAccess":{"roles":[]}}}' ;;
    *"apiAccessCreateKeys"*)
      local acct
      acct=$(sed -E 's/.*accountId: ([0-9]+),.*/\1/' <<<"$q")
      _log "M:createKey:$acct"
      _st '.keys += [{accountId:($a|tonumber), key:("lic-secret-"+$a)}]' --arg a "$acct"
      echo '{"data":{"apiAccessCreateKeys":{"createdKeys":[{"id":"k1","key":"lic-secret"}],"errors":[]}}}' ;;

    *"keySearch"*)
      local acct
      acct=$(jq -r '.acct' <<<"$v")
      jq -c --argjson a "$acct" \
        '{data:{actor:{apiAccess:{keySearch:{keys:[.keys[] | select(.accountId == $a) | {id:"k", key, name:"n", ingestType:"LICENSE", accountId}]}}}}}' "$STATE" ;;

    # grants are NOT a field on groups (real API): customerAdministration.grants by groupId
    *"grants(cursor"*)
      jq -c --argjson v "$v" \
        '{data:{customerAdministration:{grants:{nextCursor:null, items:
           [.groups[] | select(.id == $v.g) | .roles[] | {role:{id:.roleId, name:(if .roleId == "r-ro" then "Read Only" elif .roleId == "r-admin" then "All Product Admin" else .roleId end)}, scope:{id:(.accountId|tostring), type:"ACCOUNT"}}]}}}}' "$STATE" ;;
    # group lookup by name
    *"groups(filter"*)
      jq -c --argjson v "$v" \
        '($v.filter.name.eq // null) as $n
         | {data:{customerAdministration:{groups:{nextCursor:null, items:[.groups[] | select($n == null or .name == $n) | {id, name}]}}}}' "$STATE" ;;
    *"users(filter"*)
      jq -c '. as $s | {data:{customerAdministration:{users:{nextCursor:null, items:
          [.users[] | {id, email, name, groups:{items:(.groups | map(. as $g | {id:$g, name:((($s.groups[] | select(.id == $g) | .name)) // $g)}))}}]}}}}' "$STATE" ;;

    *"actor { accounts"*)
      jq -c '{data:{actor:{accounts:[.accounts[] | select(.visible) | {id, name}]}}}' "$STATE" ;;
    *"account(id:"*)
      local id
      id=$(sed -E 's/.*account\(id: ([0-9]+)\).*/\1/' <<<"$q")
      _log "Q:poll:$id"
      if jq -e --argjson i "$id" 'any(.accounts[]; .id == $i and .granted)' "$STATE" >/dev/null; then
        if jq -e --argjson i "$id" 'any(.accounts[]; .id == $i and .polls_left > 0)' "$STATE" >/dev/null; then
          _st '.accounts |= map(if .id == $i then .polls_left -= 1 else . end)' --argjson i "$id"
          echo '{"errors":[{"message":"Not authorized to access this account"}]}'
        else
          _st '.accounts |= map(if .id == $i then .visible = true else . end)' --argjson i "$id"
          echo '{"data":{"actor":{"account":{"id":'"$id"',"name":"x"}}}}'
        fi
      else
        echo '{"errors":[{"message":"Not authorized to access this account"}]}'
      fi ;;
    *)
      echo '{"errors":[{"message":"stub: unhandled query"}]}' ;;
  esac
}

# Fresh org: an Admin group + one unrelated group, optional pool users.
seed() { # seed [json array of users]
  local users="${1:-[]}"
  jq -nc --argjson u "$users" \
    '{seq:100, users:$u, groups:[{id:"g-admin", name:"Admin", roles:[]}, {id:"g-other", name:"Some Other Group", roles:[]}], accounts:[], keys:[]}' > "$STATE"
  : > "$LOG"
}

run() { ( set -euo pipefail; dispatch "$@" ); } # same strictness as the real script

# ── Tiny assertion helpers ─────────────────────
PASS=0; FAIL=0
check() { # check <description> <exit-code>
  if [[ "$2" -eq 0 ]]; then PASS=$(( PASS + 1 )); echo "  ✔ $1"; else FAIL=$(( FAIL + 1 )); echo "  ✖ $1"; fi
}
mutations() { grep -c '^M:' "$LOG" || true; }
# mutation + poll sequence with consecutive polls collapsed
sequence() { grep -E '^(M:|Q:poll)' "$LOG" | sed -E 's/^Q:poll:.*/Q:poll/' | uniq; }
eq() { [[ "$1" == "$2" ]]; echo $?; }

# ── Cases ──────────────────────────────────────
echo "case 1: accounts create 2 issues the mutations in order, per account"
seed
run accounts create 2 >"$OUT" 2>&1; rc=$?
check "returns 0" $rc
expected=$(cat <<'EOF'
M:createAccount:LAB 01
M:grant:Admin:r-admin:101
Q:poll
M:createKey:101
M:createGroup:LAB 01 - ReadOnly
M:grant:LAB 01 - ReadOnly:r-ro:101
M:createAccount:LAB 02
M:grant:Admin:r-admin:103
Q:poll
M:createKey:103
M:createGroup:LAB 02 - ReadOnly
M:grant:LAB 02 - ReadOnly:r-ro:103
EOF
)
check "order: create account → admin grant → poll → key → group → readonly grant (x2)" "$(eq "$(sequence)" "$expected")"
check "polled 3 times per account (waits for propagation)" "$(eq "$(grep -c '^Q:poll:101' "$LOG")" 3)"
check "never prints a license key value" "$(! grep -q 'lic-secret' "$OUT"; echo $?)"

echo "case 2: rerun is idempotent (zero mutations)"
: > "$LOG"
run accounts create 2 >"$OUT" 2>&1; rc=$?
check "returns 0" $rc
check "no mutations on rerun" "$(eq "$(mutations)" 0)"

echo "case 3: --dry-run issues zero mutations"
seed
run accounts create 2 --dry-run >"$OUT" 2>&1; rc=$?
check "returns 0" $rc
check "no mutations" "$(eq "$(mutations)" 0)"
check "reports what WOULD be created" "$(grep -q "WOULD create account 'LAB 01'" "$OUT"; echo $?)"
check "state untouched (no accounts)" "$(eq "$(jq '.accounts | length' "$STATE")" 0)"
: > "$LOG"
DRY_RUN=1 gql_mut 'mutation { x }' >/dev/null 2>&1; rc=$?
check "gql_mut refuses to run while DRY_RUN=1" "$([[ $rc -eq 99 ]]; echo $?)"
check "...and issued no call" "$(eq "$(mutations)" 0)"
DRY_RUN=0

echo "case 4: dry-run on a half-done org reports only the missing steps, and a real rerun resumes"
seed
run accounts create 2 >/dev/null 2>&1
_st '.keys = []'   # simulate: license keys missing
: > "$LOG"
run accounts create 2 --dry-run >"$OUT" 2>&1; rc=$?
check "dry-run: no mutations" "$(eq "$(mutations)" 0)"
check "dry-run: says it would create the license key" "$(grep -q 'WOULD create ingest LICENSE key' "$OUT"; echo $?)"
run accounts create 2 >"$OUT" 2>&1; rc=$?
check "resume returns 0" $rc
check "resume only creates the 2 missing keys" "$(eq "$(grep '^M:' "$LOG" | sort | tr '\n' ' ')" "M:createKey:101 M:createKey:103 ")"

echo "case 5: propagation never completes → clear failure"
seed
out=$(STUB_POLL_DELAY=999 LAB_PROPAGATION_POLLS=3 run accounts create 1 2>&1); rc=$?
check "returns non-zero" "$([[ $rc -ne 0 ]]; echo $?)"
check "message names the propagation problem" "$(grep -q 'still not visible' <<<"$out"; echo $?)"
check "no license key / group created for it" "$(eq "$(grep -cE '^M:(createKey|createGroup)' "$LOG")" 0)"

echo "case 6: users create skips existing users"
seed '[{"id":"u-labpool+001@example.test","email":"labpool+001@example.test","name":"x","groups":[]}]'
run users create >"$OUT" 2>&1; rc=$?
check "returns 0" $rc
check "creates only the 2 missing users" "$(eq "$(grep '^M:' "$LOG" | sort | tr '\n' ' ')" "M:createUser:labpool+002@example.test M:createUser:labpool+003@example.test ")"
check "prints the invite / shared-password reminder" "$(grep -q 'SAME shared password' "$OUT"; echo $?)"
: > "$LOG"
run users create >/dev/null 2>&1
check "rerun creates nothing" "$(eq "$(mutations)" 0)"
run users create --dry-run >/dev/null 2>&1
check "dry-run creates nothing" "$(eq "$(mutations)" 0)"
out=$( (unset POOL_USER_DOMAIN; POOL_USER_DOMAIN=""; run users create) 2>&1 ); rc=$?
check "missing POOL_USER_DOMAIN is a clear error" "$([[ $rc -ne 0 ]] && grep -q 'POOL_USER_DOMAIN is not set' <<<"$out"; echo $?)"

echo "case 7: users free removes lab-group memberships but never deletes groups"
seed '[{"id":"u1","email":"labpool+001@example.test","name":"a","groups":["g-L1"]},
       {"id":"u2","email":"labpool+002@example.test","name":"b","groups":["g-L2","g-other"]},
       {"id":"u3","email":"labpool+003@example.test","name":"c","groups":[]}]'
_st '.groups += [{id:"g-L1", name:"LAB 01 - ReadOnly", roles:[]}, {id:"g-L2", name:"LAB 02 - ReadOnly", roles:[]}]'
run users free --yes >"$OUT" 2>&1; rc=$?
check "returns 0" $rc
check "removed u1 and u2 from their lab groups only" "$(eq "$(grep '^M:' "$LOG" | sort | tr '\n' ' ')" "M:removeFromGroup:u1:g-L1 M:removeFromGroup:u2:g-L2 ")"
check "never calls the delete-group mutation" "$(eq "$(grep -c 'deleteGroup' "$LOG")" 0)"
check "all 4 groups still exist" "$(eq "$(jq '.groups | length' "$STATE")" 4)"
check "non-lab membership of u2 untouched" "$(eq "$(jq -r '.users[] | select(.id=="u2") | .groups | join(",")' "$STATE")" "g-other")"
: > "$LOG"
run users free --dry-run >/dev/null 2>&1
check "free --dry-run: no mutations" "$(eq "$(mutations)" 0)"
_st '.users |= map(if .id == "u1" then .groups = ["g-L1"] else . end)'
run users free labpool+001@example.test >"$OUT" 2>&1; rc=$?
check "free <email> frees just that user" "$(eq "$(grep '^M:' "$LOG" | tr '\n' ' ')" "M:removeFromGroup:u1:g-L1 ")"

echo "case 8: users status is read-only"
: > "$LOG"
run users status >"$OUT" 2>&1; rc=$?
check "returns 0, no mutations" "$([[ $rc -eq 0 && "$(mutations)" -eq 0 ]]; echo $?)"

echo "case 9: accounts status shows claimed-by / free / key presence, no key values"
seed '[{"id":"u1","email":"labpool+001@example.test","name":"a","groups":[]},{"id":"u2","email":"labpool+002@example.test","name":"b","groups":[]}]'
run accounts create 2 >/dev/null 2>&1
gid1=$(jq -r '.groups[] | select(.name=="LAB 01 - ReadOnly") | .id' "$STATE")
_st '.users |= map(if .id == "u1" then .groups = [$g] else . end)' --arg g "$gid1"
: > "$LOG"
run accounts status >"$OUT" 2>&1; rc=$?
check "returns 0, no mutations" "$([[ $rc -eq 0 && "$(mutations)" -eq 0 ]]; echo $?)"
check "LAB 01 shows its claimer" "$(grep -E 'LAB 01 .*labpool\+001@example.test' "$OUT" >/dev/null; echo $?)"
check "LAB 02 shows free" "$(grep -E 'LAB 02 .* free ' "$OUT" >/dev/null; echo $?)"
check "license key column says yes" "$(grep -E 'LAB 02 .* yes$' "$OUT" >/dev/null; echo $?)"
check "never prints key values" "$(! grep -q 'lic-secret' "$OUT"; echo $?)"

echo "case 10: accounts destroy (dry-run, then real)"
: > "$LOG"
run accounts destroy --dry-run >"$OUT" 2>&1; rc=$?
check "dry-run: returns 0, no mutations" "$([[ $rc -eq 0 && "$(mutations)" -eq 0 ]]; echo $?)"
run accounts destroy --yes >"$OUT" 2>&1; rc=$?
check "returns 0" $rc
check "removed the one claimed member" "$(eq "$(grep -c '^M:removeFromGroup' "$LOG")" 1)"
check "deleted both lab groups" "$(eq "$(grep -c '^M:deleteGroup' "$LOG")" 2)"
check "cancelled each account twice (4 calls)" "$(eq "$(grep -c '^M:cancel' "$LOG")" 4)"
check "removal precedes group delete precedes cancel (account 101)" \
  "$(eq "$(grep -E 'removeFromGroup|deleteGroup:'"$gid1"'|cancel:101' "$LOG" | sed -E 's/^M:([A-Za-z]+).*/\1/' | tr '\n' ' ')" "removeFromGroup deleteGroup cancel cancel ")"
check "Admin group not deleted" "$(jq -e 'any(.groups[]; .name == "Admin")' "$STATE" >/dev/null; echo $?)"

echo "case 11: bad prefix is rejected before any call"
seed
: > "$LOG"
out=$(LAB_ACCOUNT_PREFIX='LA"B' run accounts create 1 2>&1); rc=$?
check "returns non-zero with a clear message" "$([[ $rc -ne 0 ]] && grep -q 'LAB_ACCOUNT_PREFIX' <<<"$out"; echo $?)"
check "no mutations" "$(eq "$(mutations)" 0)"

echo "case 12: pair claim maps a free user to a free lab group (no Instruqt)"
seed '[{"id":"ua","email":"labpool+001@example.test","name":"a","groups":[]},{"id":"ub","email":"labpool+002@example.test","name":"b","groups":[]}]'
run accounts create 2 >/dev/null 2>&1
: > "$LOG"
run pair claim --dry-run >"$OUT" 2>&1; rc=$?
check "dry-run: returns 0, no mutations" "$([[ $rc -eq 0 && "$(mutations)" -eq 0 ]]; echo $?)"
run pair claim >"$OUT" 2>&1; rc=$?
check "random claim returns 0 with one membership write" "$([[ $rc -eq 0 && "$(grep -c '^M:addToGroup' "$LOG")" -eq 1 ]]; echo $?)"
check "prints account id and 'license key: readable'" "$(grep -q 'license key: readable' "$OUT" && grep -qE 'account: +LAB 0[12] \(id [0-9]+\)' "$OUT"; echo $?)"
check "never prints a license key value" "$(! grep -q 'lic-secret' "$OUT"; echo $?)"
run users free --yes >/dev/null 2>&1
: > "$LOG"
run pair claim labpool+002@example.test "LAB 02" >"$OUT" 2>&1; rc=$?
check "named claim maps exactly that pair" "$([[ $rc -eq 0 ]] && grep -q 'M:addToGroup:ub:' "$LOG" && grep -q 'user: *labpool+002@example.test' "$OUT"; echo $?)"
: > "$LOG"
run pair claim labpool+002@example.test "LAB 01" >"$OUT" 2>&1; rc=$?
check "named claim of an already-claimed user is refused, no writes" "$([[ $rc -ne 0 && "$(mutations)" -eq 0 ]] && grep -q 'already in a group' "$OUT"; echo $?)"
run pair claim labpool+001@example.test "LAB 02" >"$OUT" 2>&1; rc=$?
check "named claim of an occupied group is refused, no writes" "$([[ $rc -ne 0 && "$(mutations)" -eq 0 ]] && grep -q 'already has a member' "$OUT"; echo $?)"
run users free --yes >/dev/null 2>&1
run pair claim labpool+001@example.test LAB 01 >"$OUT" 2>&1; rc=$?
check "unquoted account name (LAB 01) is re-joined and works" "$([[ $rc -eq 0 ]] && grep -q 'group: *LAB 01 - ReadOnly' "$OUT"; echo $?)"
run pair claim labpool+001@example.test >"$OUT" 2>&1; rc=$?
check "email without account name is rejected" "$([[ $rc -ne 0 ]]; echo $?)"

echo "case 13: grants are read from customerAdministration.grants, and status shows them"
seed '[{"id":"ua","email":"labpool+001@example.test","name":"a","groups":[]}]'
run accounts create 2 >/dev/null 2>&1
: > "$LOG"
run accounts create 2 >"$OUT" 2>&1; rc=$?
check "rerun sees existing grants (no grant mutation re-sent)" "$([[ $rc -eq 0 ]] && ! grep -q '^M:grant' "$LOG"; echo $?)"
check "rerun reports '<role> grant exists'" "$(grep -q 'read_only grant exists' "$OUT"; echo $?)"
run accounts status >"$OUT" 2>&1; rc=$?
check "status shows the group's role on its account" "$([[ $rc -eq 0 ]] && grep -E 'LAB 01 .* Read Only ' "$OUT" >/dev/null; echo $?)"
_st '.groups |= map(if .name == "LAB 02 - ReadOnly" then .roles = [] else . end)'
run accounts status >"$OUT" 2>&1; rc=$?
check "a group with no grant shows NONE" "$(grep -E 'LAB 02 .* NONE ' "$OUT" >/dev/null; echo $?)"
check "…and status warns about it" "$(grep -q 'hold no grant on their account' "$OUT"; echo $?)"
: > "$LOG"
run accounts create 2 >"$OUT" 2>&1; rc=$?
check "accounts create re-grants only the stripped group" "$(eq "$(grep '^M:' "$LOG" | tr '\n' ' ')" "M:grant:LAB 02 - ReadOnly:r-ro:103 ")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
