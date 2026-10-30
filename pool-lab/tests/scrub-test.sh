#!/usr/bin/env bash
# ─────────────────────────────────────────────
# Offline test for lib/scrub.sh (scrub_account) and `provision.sh accounts scrub`.
# No network: gql is replaced by an in-memory NerdGraph stub that records every mutation.
# Usage: ./tests/scrub-test.sh
# ─────────────────────────────────────────────
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
source "$_HERE/../provision.sh"

POOL_EMAIL_PREFIX="labpool+"
LAB_ACCOUNT_PREFIX="LAB"

STATE="$(mktemp)"
LOG="$(mktemp)"
OUT="$(mktemp)"
trap 'rm -f "$STATE" "$STATE.tmp" "$LOG" "$OUT"' EXIT

_log() { echo "$1" >> "$LOG"; }

# Every list answers from $STATE. Policies come in two pages to exercise the cursor.
gql() {
  local q v
  q=$(jq -r '.query' <<<"$1")
  v=$(jq -c '.variables // {}' <<<"$1")
  case "$q" in
    *"organization { id }"*)
      echo '{"data":{"actor":{"organization":{"id":"org-1"}}}}' ;;
    *"authenticationDomains(filter"*)
      echo '{"data":{"customerAdministration":{"authenticationDomains":{"items":[{"id":"dom-1","name":"Default"}]}}}}' ;;
    *"users(filter"*)
      jq -c '{data:{customerAdministration:{users:{nextCursor:null, items:
          [.users[] | {id, email, name, groups:{items:(.groups | map({id:., name:.}))}}]}}}}' "$STATE" ;;
    *"groups(filter"*)
      jq -c '{data:{customerAdministration:{groups:{nextCursor:null, items:[.groups[] | {id, name}]}}}}' "$STATE" ;;
    *"accounts { id name }"*)
      jq -c '{data:{actor:{accounts:.accounts}}}' "$STATE" ;;
    *"actor { user { id } }"*)
      echo '{"data":{"actor":{"user":{"id":42}}}}' ;;

    *"workflowAutomation { schedules"*)
      jq -c '{data:{actor:{account:{workflowAutomation:{schedules:{results:
          [.schedules[] | {schedule:{id:.}, definition:{name:("def-of-"+.)}}]}}}}}}' "$STATE" ;;
    *"workflowAutomation { workflows"*)
      jq -c '{data:{actor:{account:{workflowAutomation:{workflows:{nextCursor:null, results:
          [.definitions[] | {definition:{name:.name, scope:{id:"x", type:.scope}}}]}}}}}}' "$STATE" ;;
    *"aiWorkflows { workflows"*)
      jq -c '{data:{actor:{account:{aiWorkflows:{workflows:{nextCursor:null, entities:.workflows}}}}}}' "$STATE" ;;
    *"channels(cursor"*)
      jq -c '{data:{actor:{account:{aiNotifications:{channels:{nextCursor:null, entities:.channels}}}}}}' "$STATE" ;;
    *"destinations(cursor"*)
      jq -c '{data:{actor:{account:{aiNotifications:{destinations:{nextCursor:null, entities:.destinations}}}}}}' "$STATE" ;;
    *"mutingRules"*)
      jq -c '{data:{actor:{account:{alerts:{mutingRules:.muting}}}}}' "$STATE" ;;
    *"policiesSearch"*)
      if [[ "$(jq -r '.cursor // ""' <<<"$v")" == "" ]]; then
        jq -c '{data:{actor:{account:{alerts:{policiesSearch:{nextCursor:"p2", policies:.policies[:1]}}}}}}' "$STATE"
      else
        jq -c '{data:{actor:{account:{alerts:{policiesSearch:{nextCursor:null, policies:.policies[1:]}}}}}}' "$STATE"
      fi ;;
    *"aiIssues { issues"*)
      jq -c '{data:{actor:{account:{aiIssues:{issues:{nextCursor:null, issues:[.issues[] | {issueId:.}]}}}}}}' "$STATE" ;;
    *"entitySearch"*)
      jq -c '{data:{actor:{entitySearch:{results:{nextCursor:null, entities:.entities}}}}}' "$STATE" ;;
    *"keySearch"*)
      jq -c '{data:{actor:{apiAccess:{keySearch:{nextCursor:null, keys:.userkeys}}}}}' "$STATE" ;;

    *"workflowAutomationDeleteSchedule"*)  _log "M:wfa-schedule:$(jq -r .id <<<"$v")"; echo '{"data":{"workflowAutomationDeleteSchedule":{"scheduleId":"s"}}}' ;;
    *"workflowAutomationDeleteWorkflowDefinition"*)
      _log "M:wfa-definition:$(jq -r .n <<<"$v"):scope=$(jq -r .s <<<"$v")"; echo '{"data":{"workflowAutomationDeleteWorkflowDefinition":{"definition":{"name":"d"}}}}' ;;
    *"aiWorkflowsDeleteWorkflow"*)         _log "M:ai-workflow:$(jq -r .id <<<"$v")"; echo '{"data":{"aiWorkflowsDeleteWorkflow":{"id":"w","errors":[]}}}' ;;
    *"aiNotificationsDeleteChannel"*)      _log "M:channel:$(jq -r .id <<<"$v")"; echo '{"data":{"aiNotificationsDeleteChannel":{"ids":["c"],"error":null}}}' ;;
    *"aiNotificationsDeleteDestination"*)
      _log "M:destination:$(jq -r .id <<<"$v")"
      if [[ "$(jq -r .id <<<"$v")" == "dest-busy" ]]; then
        echo '{"data":{"aiNotificationsDeleteDestination":{"ids":[],"error":{"description":"destination in use","details":""}}}}'
      else
        echo '{"data":{"aiNotificationsDeleteDestination":{"ids":["d"],"error":null}}}'
      fi ;;
    *"alertsMutingRuleDelete"*)            _log "M:muting:$(jq -r .id <<<"$v")"; echo '{"data":{"alertsMutingRuleDelete":{"id":"m"}}}' ;;
    *"alertsPolicyDelete"*)                _log "M:policy:$(jq -r .id <<<"$v")"; echo '{"data":{"alertsPolicyDelete":{"id":"p"}}}' ;;
    *"aiIssuesResolveIssue"*)              _log "M:issue:$(jq -r .id <<<"$v")"; echo '{"data":{"aiIssuesResolveIssue":{"error":null,"result":{"issueId":"i"}}}}' ;;
    *"dashboardDelete"*)                   _log "M:dashboard:$(jq -r .g <<<"$v")"; echo '{"data":{"dashboardDelete":{"status":"SUCCESS","errors":[]}}}' ;;
    *"syntheticsDeleteMonitor"*)           _log "M:monitor:$(jq -r .g <<<"$v")"; echo '{"data":{"syntheticsDeleteMonitor":{"deletedGuid":"g"}}}' ;;
    *"entityDelete"*)
      _log "M:entities:$(jq -r '.g | join(",")' <<<"$v")"
      jq -c -n --argjson g "$(jq -c .g <<<"$v")" --argjson fail "$(jq -c '.fail' "$STATE")" \
        '{data:{entityDelete:{deletedEntities:[$g[] | select(. as $x | $fail | index($x) == null)],
                             failures:[$g[] | select(. as $x | $fail | index($x) != null) | {guid:., message:"cannot delete", type:"X"}]}}}' ;;
    *"agentApplicationDelete"*)            _log "M:apm-app:$(jq -r .g <<<"$v")"; echo '{"data":{"agentApplicationDelete":{"success":true}}}' ;;
    *"apiAccessDeleteKeys"*)               _log "M:userkeys:$(jq -r '.ids | join(",")' <<<"$v")"; echo '{"data":{"apiAccessDeleteKeys":{"deletedKeys":[{"id":"k"}],"errors":[]}}}' ;;
    *) echo '{"errors":[{"message":"stub: unhandled query"}]}' ;;
  esac
}

# seed [extra jq to apply]: two lab accounts and one production account, a full set of objects
seed() {
  jq -n '{
    accounts: [{id:1001, name:"LAB 01"}, {id:1002, name:"LAB 02"}, {id:999, name:"Production"}],
    users: [{id:"u1", email:"labpool+1@example.test", name:"U1", groups:[]},
            {id:"7", email:"labpool+7@example.test", name:"U7", groups:[]}],
    groups: [{id:"g1", name:"LAB 01 - ReadOnly"}, {id:"g2", name:"LAB 02 - ReadOnly"}],
    schedules: ["sch-1"],
    definitions: [{name:"shop_api_error_rollback", scope:"ACCOUNT"}, {name:"shop_api_error_rollback", scope:"ACCOUNT"},
                  {name:"newrelic_builtin", scope:"GLOBAL"}],
    workflows: [{id:"wf-1", name:"Challenge 5 - Auto-Remediation"}],
    channels: [{id:"ch-1", name:"email channel"}],
    destinations: [{id:"dest-1", name:"WFA destination"}],
    muting: [{id:"mr-1", name:"maintenance"}],
    policies: [{id:"pol-1", name:"Challenge 2 - Baseline"}, {id:"pol-2", name:"Challenge 5 - Auto-Remediation"}],
    issues: ["iss-1"],
    entities: [
      {guid:"dash-1", name:"Board", type:"DASHBOARD", domain:"VIZ", dashboardParentGuid:null},
      {guid:"dash-1-page", name:"Board / Page 1", type:"DASHBOARD", domain:"VIZ", dashboardParentGuid:"dash-1"},
      {guid:"mon-1", name:"ping", type:"MONITOR", domain:"SYNTH"},
      {guid:"apm-1", name:"wfa-shop-api", type:"APPLICATION", domain:"APM"},
      {guid:"apm-fail", name:"wfa-loadgen", type:"APPLICATION", domain:"APM"},
      {guid:"host-1", name:"wfa-infra", type:"HOST", domain:"INFRA"},
      {guid:"aiops-1", name:"Challenge 2 - Baseline", type:"POLICY", domain:"AIOPS"}],
    fail: ["apm-fail"],
    userkeys: [{id:"key-own", name:"caller", userId:42}, {id:"key-learner", name:"wfa-lab", userId:7},
               {id:"key-instructor", name:"instructor tooling", userId:55}]
  }' > "$STATE"
  if [[ -n "${1:-}" ]]; then jq "$1" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; fi
  : > "$LOG"
}

PASS=0; FAIL=0
check() { # check <description> <exit-code>
  if [[ "$2" == 0 ]]; then PASS=$(( PASS + 1 )); echo "  ok   $1"; else FAIL=$(( FAIL + 1 )); echo "  FAIL $1"; fi
}
eq() { [[ "$1" == "$2" ]]; echo $?; }
has() { grep -q -- "$1" "$LOG"; echo $?; }
hasnt() { if grep -q -- "$1" "$LOG"; then echo 1; else echo 0; fi; }
mutations() { grep -c '^M:' "$LOG" || true; }
first() { grep -n -- "^M:$1" "$LOG" | head -1 | cut -d: -f1; }

echo "case 1: refuses an account that is not a lab account"
seed
( set -euo pipefail; scrub_account 999 ) >"$OUT" 2>&1; rc=$?
check "returns non-zero" "$(eq "$rc" 1)"
check "no mutation" "$(eq "$(mutations)" 0)"
check "says why" "$(grep -q "refusing account 999" "$OUT"; echo $?)"
( set -euo pipefail; scrub_account abc ) >"$OUT" 2>&1; rc=$?
check "rejects a non-numeric id" "$(eq "$rc" 1)"

echo "case 2: dry run lists and sends nothing"
seed
( set -euo pipefail; DRY_RUN=1 scrub_account 1001 ) >"$OUT" 2>&1; rc=$?
check "returns 0" "$rc"
check "no mutation" "$(eq "$(mutations)" 0)"
check "lists alert policies across both pages" "$(grep -q "alert policies: would delete 2" "$OUT"; echo $?)"
check "lists the learner key only" "$(grep -q "user keys: would delete 1: wfa-lab (user 7)" "$OUT"; echo $?)"

echo "case 3: real run deletes in dependency order"
seed
( set -euo pipefail; scrub_account 1001 ) >"$OUT" 2>&1; rc=$?
check "returns 0 (APM fallback recovered the one failure)" "$rc"
order_ok=0
prev=0
for k in wfa-schedule wfa-definition ai-workflow channel destination muting policy issue dashboard monitor entities userkeys; do
  n=$(first "$k")
  if [[ -z "$n" || "$n" -le "$prev" ]]; then order_ok=1; echo "    order broken at $k (line ${n:-none} after $prev)"; fi
  prev=${n:-$prev}
done
check "order: WFA, alert workflows, channels, destinations, muting, policies, issues, dashboards, monitors, entities, keys" "$order_ok"
check "definition deleted once (names are de-duplicated)" "$(eq "$(grep -c '^M:wfa-definition:shop_api_error_rollback' "$LOG")" 1)"
check "definition scoped to the account" "$(has 'M:wfa-definition:shop_api_error_rollback:scope=1001')"
check "GLOBAL definition left alone" "$(hasnt 'newrelic_builtin')"
check "both policy pages deleted" "$(eq "$(grep -c '^M:policy:' "$LOG")" 2)"
check "dashboard deleted, its page not" "$(eq "$(grep -c '^M:dashboard:' "$LOG")" 1)"
check "monitor deleted through synthetics" "$(has 'M:monitor:mon-1')"
check "entities force-deleted in one batch without dashboards and monitors" "$(has 'M:entities:apm-1,apm-fail,host-1$')"
check "rejected APM app retried with agentApplicationDelete" "$(has 'M:apm-app:apm-fail')"
check "learner key deleted" "$(has 'M:userkeys:key-learner$')"
check "caller's own key kept" "$(hasnt 'key-own')"
check "a non-pool user's key kept" "$(hasnt 'key-instructor')"
check "AIOPS index entities not force-deleted" "$(hasnt 'aiops-1')"

echo "case 4: a delete that fails makes the scrub report failure"
seed '.fail = ["host-1"] | .destinations += [{id:"dest-busy", name:"busy"}]'
( set -euo pipefail; scrub_account 1001 ) >"$OUT" 2>&1; rc=$?
check "returns non-zero" "$(eq "$rc" 1)"
check "warns about the host entity" "$(grep -q "entity host-1: cannot delete" "$OUT"; echo $?)"
check "warns about the payload error" "$(grep -q "destination busy: destination in use" "$OUT"; echo $?)"
check "carries on after a failure (keys still deleted)" "$(has 'M:userkeys:key-learner')"

echo "case 5: an empty account is a clean no-op"
seed '.schedules=[] | .definitions=[] | .workflows=[] | .channels=[] | .destinations=[] | .muting=[] | .policies=[] | .issues=[] | .entities=[] | .userkeys=[{id:"key-own", name:"instructor", userId:42}]'
( set -euo pipefail; scrub_account 1001 ) >"$OUT" 2>&1; rc=$?
check "returns 0" "$rc"
check "no mutation" "$(eq "$(mutations)" 0)"

echo "case 6: accounts scrub skips a claimed account unless --force"
run() { ( set -euo pipefail; dispatch "$@" ); }
seed '.users[0].groups = ["g2"]'
run accounts scrub LAB 02 --yes >"$OUT" 2>&1; rc=$?
check "returns 0" "$rc"
check "no mutation on the claimed account" "$(eq "$(mutations)" 0)"
check "says it is claimed" "$(grep -q "LAB 02 is claimed by labpool+1@example.test" "$OUT"; echo $?)"
: > "$LOG"
run accounts scrub LAB 02 --yes --force >"$OUT" 2>&1; rc=$?
check "--force scrubs it" "$(has 'M:policy:pol-1')"

echo "case 7: accounts scrub --dry-run and --all"
seed
run accounts scrub --all --dry-run >"$OUT" 2>&1; rc=$?
check "dry run returns 0" "$rc"
check "dry run sends no mutation" "$(eq "$(mutations)" 0)"
check "--all covers both lab accounts and not Production" "$(eq "$(grep -c "scrubbing 'LAB 0" "$OUT")" 2)"
run accounts scrub Production --yes >"$OUT" 2>&1; rc=$?
check "a non-lab account name is rejected" "$(eq "$rc" 1)"
run accounts scrub --yes >"$OUT" 2>&1; rc=$?
check "no target is a usage error" "$(eq "$rc" 2)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" == 0 ]]
