#!/usr/bin/env bash
# ─────────────────────────────────────────────
# Offline test for lab/bootstrap.sh and lab/teardown.sh. No network, no New Relic calls.
# 1. Builds setup-lab / cleanup-lab with build-lab-scripts.sh into a temp dir.
# 2. Runs the BUILT files with POOL_LAB_TEST_STUB pointing at an in-memory NerdGraph stub
#    (test seam: the scripts source that file right after the libs, so it overrides gql/sleep).
# 3. Agent variables go to a temp POOL_LAB_VAR_DIR (file store), so no real `agent` is touched.
# Usage: ./tests/bootstrap-test.sh
# ─────────────────────────────────────────────
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v agent >/dev/null 2>&1; then
  echo "refusing to run: a real 'agent' CLI is on PATH ($(command -v agent))"; exit 2
fi

OUT="$TMP/dist"
"$_HERE/../build-lab-scripts.sh" --vm lab --out "$OUT" >/dev/null || { echo "build failed"; exit 1; }

STATE="$TMP/state.json"
VARS="$TMP/vars"
STUB="$TMP/stub.sh"

# ── In-memory NerdGraph stub (sourced by the built scripts) ──
# State: {"users":[{id,email,name,groups:[gid..]}], "groups":[{id,name}],
#         "accounts":[{id,name}], "keys":[{accountId,key}]}
cat > "$STUB" <<'STUBEOF'
sleep() { :; }
gql() {
  local q v
  q=$(jq -r '.query' <<<"$1")
  v=$(jq -c '.variables // {}' <<<"$1")
  if [[ "$q" == *"AddUsersToGroups"* ]]; then
    local gid uid
    gid=$(jq -r '.opts.groupIds[0]' <<<"$v"); uid=$(jq -r '.opts.userIds[0]' <<<"$v")
    echo "$uid $gid" >> "$POOL_LAB_TEST_STATE.adds"
    jq --arg uid "$uid" --arg gid "$gid" \
      '.users |= map(if .id == $uid then .groups = ((.groups + [$gid]) | unique) else . end)' \
      "$POOL_LAB_TEST_STATE" > "$POOL_LAB_TEST_STATE.tmp" && mv "$POOL_LAB_TEST_STATE.tmp" "$POOL_LAB_TEST_STATE"
    echo '{"data":{"userManagementAddUsersToGroups":{"groups":[]}}}'
  elif [[ "$q" == *"RemoveUsersFromGroups"* ]]; then
    local gid uid
    gid=$(jq -r '.opts.groupIds[0]' <<<"$v"); uid=$(jq -r '.opts.userIds[0]' <<<"$v")
    jq --arg uid "$uid" --arg gid "$gid" \
      '.users |= map(if .id == $uid then .groups -= [$gid] else . end)' \
      "$POOL_LAB_TEST_STATE" > "$POOL_LAB_TEST_STATE.tmp" && mv "$POOL_LAB_TEST_STATE.tmp" "$POOL_LAB_TEST_STATE"
    echo '{"data":{"userManagementRemoveUsersFromGroups":{"groups":[]}}}'
  elif [[ "$q" == *"organization { id }"* ]]; then
    echo '{"data":{"actor":{"organization":{"id":"org-1"}}}}'
  elif [[ "$q" == *"authenticationDomains"* ]]; then
    echo '{"data":{"customerAdministration":{"authenticationDomains":{"items":[{"id":"dom-1","name":"Default"}]}}}}'
  elif [[ "$q" == *"users(filter"* ]]; then
    jq -c '{data:{customerAdministration:{users:{nextCursor:null, items:
        [.users[] | {id, email, name, groups:{items:(.groups | map({id:., name:.}))}}]}}}}' "$POOL_LAB_TEST_STATE"
  elif [[ "$q" == *"grants(cursor"* ]]; then
    jq -c --argjson v "$v" '{data:{customerAdministration:{grants:{nextCursor:null, items:
        [.groups[] | select(.id == $v.g) | (.grants // [])[] | {role:{id:1254, name:"All Product Admin"}, scope:{id:(tostring), type:"ACCOUNT"}}]}}}}' \
      "$POOL_LAB_TEST_STATE"
  elif [[ "$q" == *"groups(filter"* ]]; then
    jq -c '{data:{customerAdministration:{groups:{nextCursor:null, items:[.groups[] | {id, name}]}}}}' "$POOL_LAB_TEST_STATE"
  elif [[ "$q" == *"keySearch"* ]]; then
    local acct
    acct=$(jq -r '.acct' <<<"$v")
    jq -c --argjson a "$acct" '{data:{actor:{apiAccess:{keySearch:{keys:
        [.keys[] | select(.accountId == $a) | {id:"k", key:.key, name:"lab", ingestType:"LICENSE", accountId:.accountId}]}}}}}' \
      "$POOL_LAB_TEST_STATE"
  elif [[ "$q" == *"accounts { id name }"* ]]; then
    jq -c '{data:{actor:{accounts:.accounts}}}' "$POOL_LAB_TEST_STATE"
  else
    echo '{"errors":[{"message":"stub: unhandled query"}]}'
  fi
}
STUBEOF

# seed <users> <groups> <with-keys 1|0> [<with-accounts 1|0>]
seed() {
  local u g a k
  u=$(jq -nc --argjson n "$1" '[range(1; $n+1) | {id:("u\(.)"), email:("labpool+\(.)@example.test"), name:("Lab User \(.)"), groups:[]}]
        + [{id:"u-outsider", email:"someone@example.test", name:"Outsider", groups:[]}]')
  g=$(jq -nc --argjson n "$2" '[range(1; $n+1) | {id:("g\(.)"), name:("LAB 0\(.) - ReadOnly"), grants:[1000+.]}]
        + [{id:"g-nonlab", name:"Some Other Group"}]')
  a=$(jq -nc --argjson n "$2" --argjson w "${4:-1}" 'if $w == 1 then [range(1; $n+1) | {id:(1000+.), name:("LAB 0\(.)")}] else [] end')
  k=$(jq -nc --argjson n "$2" --argjson w "$3" 'if $w == 1 then [range(1; $n+1) | {accountId:(1000+.), key:("KEY-\(1000+.)-SECRETVALUE")}] else [] end')
  jq -nc --argjson u "$u" --argjson g "$g" --argjson a "$a" --argjson k "$k" \
    '{users:$u, groups:$g, accounts:$a, keys:$k}' > "$STATE"
  rm -f "$STATE.adds" "$STATE.tmp"
  rm -rf "$VARS"
}

# run_script <built script name> → stdout+stderr in $RUN_OUT, exit code in $RUN_RC
run_script() {
  RUN_OUT=$(env \
    POOL_LAB_TEST_STUB="$STUB" POOL_LAB_TEST_STATE="$STATE" POOL_LAB_VAR_DIR="$VARS" \
    LAB_NR_API_KEY_SECRET=T_API_KEY T_API_KEY=fake-api-key \
    LAB_USER_PASSWORD_SECRET=T_PASSWORD T_PASSWORD=shared-pw-VALUE \
    POOL_EMAIL_PREFIX="labpool+" LAB_ACCOUNT_PREFIX="LAB" \
    LAB_CLAIM_JITTER_MAX=0 LAB_VERIFY_SLEEP=0 \
    bash "$OUT/$1" 2>&1)
  RUN_RC=$?
}

PASS=0; FAIL=0
check() { # check <description> <exit code>
  if [[ "$2" -eq 0 ]]; then PASS=$(( PASS + 1 )); echo "  ✔ $1"; else FAIL=$(( FAIL + 1 )); echo "  ✖ $1"; fi
}
var() { cat "$VARS/$1" 2>/dev/null; }
placed_users() { jq '[.users[] | select((.email|startswith("labpool+")) and (.groups|length)>0)] | length' "$STATE"; }
group_members() { jq --arg id "$1" '[.users[] | select(.groups | index($id) != null)] | length' "$STATE"; }
user_groups() { jq --arg id "$1" '[.users[] | select(.id == $id)] | .[0].groups | length' "$STATE"; }

echo "case 1: happy path"
seed 3 3 1
run_script setup-lab
check "exits 0" $RUN_RC
[[ $RUN_RC -ne 0 ]] && echo "$RUN_OUT" | sed 's/^/      /'
uid=$(var POOL_USER_ID); gid=$(var POOL_GROUP_ID)
check "all 11 agent vars are set" "$(for k in NEW_RELIC_ACCOUNT_ID NEW_RELIC_LICENSE_KEY ACCOUNT_NAME NR_ORG_ID POOL_USER_ID POOL_USER_EMAIL POOL_USER_NAME USER_EMAIL USER_NAME POOL_GROUP_ID LAB_USER_PASSWORD; do [[ -s "$VARS/$k" ]] || exit 1; done; echo 0)"
check "exactly one pool user placed, in exactly one group" "$([[ "$(placed_users)" == 1 && "$(user_groups "$uid")" == 1 ]]; echo $?)"
check "claimed group has exactly one member" "$([[ "$(group_members "$gid")" == 1 ]]; echo $?)"
n="${gid#g}"
check "account id/name/key match the claimed group" "$([[ "$(var NEW_RELIC_ACCOUNT_ID)" == "$((1000 + n))" && "$(var ACCOUNT_NAME)" == "LAB 0$n" && "$(var NEW_RELIC_LICENSE_KEY)" == "KEY-$((1000 + n))-SECRETVALUE" ]]; echo $?)"
check "MARS-compat vars mirror the pool user" "$([[ "$(var USER_EMAIL)" == "$(var POOL_USER_EMAIL)" && "$(var USER_NAME)" == "$(var POOL_USER_NAME)" && "$(var NR_ORG_ID)" == org-1 && "$(var LAB_USER_PASSWORD)" == shared-pw-VALUE ]]; echo $?)"
check "output never prints the license key, password or api key" "$(! grep -qE 'SECRETVALUE|shared-pw-VALUE|fake-api-key' <<<"$RUN_OUT"; echo $?)"
adds_before=$(wc -l < "$STATE.adds" | tr -d ' ')

echo "case 2: re-run is idempotent"
run_script setup-lab
check "exits 0" $RUN_RC
check "no second claim (add-to-group called once in total)" "$([[ "$(wc -l < "$STATE.adds" | tr -d ' ')" == "$adds_before" ]]; echo $?)"
check "same pair and still exactly one user placed" "$([[ "$(var POOL_USER_ID)" == "$uid" && "$(var POOL_GROUP_ID)" == "$gid" && "$(placed_users)" == 1 ]]; echo $?)"
check "reports reusing the claim" "$(grep -q 'reusing existing claim' <<<"$RUN_OUT"; echo $?)"

echo "case 3: teardown releases the user, keeps the group"
run_script cleanup-lab
check "exits 0" $RUN_RC
check "user is in no group" "$([[ "$(user_groups "$uid")" == 0 && "$(placed_users)" == 0 ]]; echo $?)"
check "group still exists" "$([[ "$(jq --arg id "$gid" '[.groups[] | select(.id == $id)] | length' "$STATE")" == 1 ]]; echo $?)"
check "account untouched" "$([[ "$(jq '.accounts | length' "$STATE")" == 3 ]]; echo $?)"
run_script cleanup-lab
check "teardown is tolerant of a second run" $RUN_RC
rm -rf "$VARS"
run_script cleanup-lab
check "teardown tolerates missing vars (exit 0)" $RUN_RC

echo "case 4: missing license key fails and releases the claim"
seed 3 3 0
run_script setup-lab
check "exits non-zero" "$([[ $RUN_RC -ne 0 ]]; echo $?)"
check "message tells the instructor to run provision.sh accounts create" "$(grep -q 'provision.sh accounts create' <<<"$RUN_OUT"; echo $?)"
check "claim was made, then released (no user left in a group)" "$([[ -f "$STATE.adds" && "$(placed_users)" == 0 ]]; echo $?)"
check "failed step is reported" "$(grep -q "failed during step\|No ingest license key" <<<"$RUN_OUT"; echo $?)"

echo "case 5: group without a sub-account fails and releases the claim"
seed 3 3 1 0
run_script setup-lab
check "exits non-zero" "$([[ $RUN_RC -ne 0 ]]; echo $?)"
check "claim released" "$([[ "$(placed_users)" == 0 ]]; echo $?)"

echo "case 5b: group with no grant on its account fails and releases the claim"
seed 1 1 1
jq '.groups |= map(.grants = [])' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_script setup-lab
check "exits non-zero" "$([[ $RUN_RC -ne 0 ]]; echo $?)"
check "says the group holds no grant" "$(grep -q 'holds no grant on account' <<<"$RUN_OUT"; echo $?)"
check "claim released" "$([[ -f "$STATE.adds" && "$(placed_users)" == 0 ]]; echo $?)"

echo "case 5c: teardown warns when the license key was deleted during the lab"
seed 1 1 1
run_script setup-lab
check "setup exits 0" $RUN_RC
check "setup reports the learner role" "$(grep -q 'learner role on account 1001: All Product Admin' <<<"$RUN_OUT"; echo $?)"
jq '.keys = []' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_script cleanup-lab
check "teardown still exits 0" $RUN_RC
check "teardown warns that the key is gone" "$(grep -q 'NO ingest license key' <<<"$RUN_OUT"; echo $?)"

echo "case 6: missing API key secret fails clearly"
seed 3 3 1
RUN_OUT=$(env -u T_API_KEY POOL_LAB_TEST_STUB="$STUB" POOL_LAB_TEST_STATE="$STATE" POOL_LAB_VAR_DIR="$VARS" \
  LAB_NR_API_KEY_SECRET=T_API_KEY bash "$OUT/setup-lab" 2>&1); RUN_RC=$?
check "exits non-zero" "$([[ $RUN_RC -ne 0 ]]; echo $?)"
check "names the missing env var" "$(grep -q "'T_API_KEY'" <<<"$RUN_OUT"; echo $?)"
check "nothing claimed" "$([[ "$(placed_users)" == 0 ]]; echo $?)"

echo "case 7: built files are self-contained"
for f in setup-lab cleanup-lab; do
  check "$f has no source/. of lib paths, no inline marker, is executable, passes bash -n" \
    "$(! grep -qE '(^|[[:space:]])(source|\.)[[:space:]].*lib/|pool-lab:inline' "$OUT/$f" && [[ -x "$OUT/$f" ]] && bash -n "$OUT/$f"; echo $?)"
  check "$f has exactly one shebang" "$([[ "$(grep -c '^#!' "$OUT/$f")" == 1 ]]; echo $?)"
done
# run from an empty dir with no lib/ nearby to prove no runtime file dependency
mkdir "$TMP/isolated" && cp "$OUT/setup-lab" "$TMP/isolated/"
seed 2 2 1
RUN_OUT=$(cd "$TMP/isolated" && env POOL_LAB_TEST_STUB="$STUB" POOL_LAB_TEST_STATE="$STATE" POOL_LAB_VAR_DIR="$VARS" \
  LAB_NR_API_KEY_SECRET=T_API_KEY T_API_KEY=fake LAB_CLAIM_JITTER_MAX=0 LAB_VERIFY_SLEEP=0 bash ./setup-lab 2>&1); RUN_RC=$?
check "setup-lab runs from an isolated copy" $RUN_RC

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
