# ─────────────────────────────────────────────
# pool-lab account scrub: delete everything a learner may have created in a lab account, so the
# next learner who claims it starts from blank. Used by lab/teardown.sh (lab end) and by
# `provision.sh accounts scrub` (instructor). Requires lib/common.sh. Bash 3.2 compatible.
#
# Deletes, in this order (dependents first): Workflow Automation schedules and definitions,
# alert workflows (with their channels), remaining channels, destinations (including the
# Workflow Automation destination that stores the learner's NRAK key), muting rules, alert
# policies (with their conditions), open issues, dashboards, synthetic monitors, every other
# entity (force), and the USER keys that pool users own on the account.
# Never deletes: ingest keys, keys of anyone who is not a pool user (instructors), the account
# itself, the lab group, or telemetry already stored. AIOPS entities (policy, condition, workflow,
# destination) are index entries of the alert objects deleted above, so they are not force-deleted.
#
# Query and mutation shapes were checked by read-only schema introspection on 2026-10-30.
# The deletes themselves have not run against a real account yet.
# Honors DRY_RUN=1: lists what it would delete and sends no mutation.
# ─────────────────────────────────────────────

SCRUB_MAX_PAGES="${SCRUB_MAX_PAGES:-50}"
SCRUB_ENTITY_BATCH="${SCRUB_ENTITY_BATCH:-25}"
SCRUB_ISSUE_DAYS="${SCRUB_ISSUE_DAYS:-30}"

# Single choke point for scrub writes: refuses to run during a dry run.
_scrub_mut() { # _scrub_mut <query> [variables-json]
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    print_err "internal error: mutation attempted during a dry run (blocked)"
    return 99
  fi
  gql_query "$@"
}

# _scrub_ok <what> <response> [<jq for an error inside the payload>] → 0 when the call succeeded
_scrub_ok() {
  local err
  err=$(gql_err "$2")
  if [[ -z "$err" && -n "${3:-}" ]]; then
    err=$(jq -r "($3) // empty" <<<"$2" 2>/dev/null || true)
  fi
  if [[ -n "$err" ]]; then
    print_warn "    $1: $err"
    return 1
  fi
}

# _scrub_list <query> <variables-json> <jq path to the item array> [<jq path to nextCursor>]
# → JSON array of the items over every page. The query must declare $cursor when paginated.
_scrub_list() {
  local q="$1" base="$2" items="$3" cpath="${4:-}" all="[]" cursor="" vars result page next pages=0
  while true; do
    if [[ -n "$cpath" ]]; then
      vars=$(jq -c --arg c "$cursor" '. + {cursor: (if $c == "" then null else $c end)}' <<<"$base")
    else
      vars="$base"
    fi
    result=$(gql_query "$q" "$vars")
    if [[ -n "$(gql_err "$result")" ]]; then
      print_warn "  could not list: $(gql_err "$result")"
      return 1
    fi
    page=$(jq -c "[(($items) // [])[]]" <<<"$result")
    all=$(jq -c -n --argjson a "$all" --argjson b "$page" '$a + $b')
    [[ -n "$cpath" ]] || break
    next=$(jq -r "($cpath) // empty" <<<"$result")
    pages=$(( pages + 1 ))
    if [[ -z "$next" || "$next" == "$cursor" || "$pages" -ge "$SCRUB_MAX_PAGES" ]]; then break; fi
    cursor="$next"
  done
  echo "$all"
}

# _scrub_each <label> <items json [{id, name}]> <delete function> → deletes item by item
_scrub_each() {
  local label="$1" items="$2" fn="$3" n item ok=0 bad=0
  n=$(jq 'length' <<<"$items")
  if [[ "$n" == 0 ]]; then
    echo "  ${label}: none"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    echo "  ${label}: would delete ${n}: $(jq -r '[.[] | (.name // .id) | tostring] | .[:8] | join(", ")' <<<"$items")$(if (( n > 8 )); then echo ', ...'; fi)"
    SCRUB_PLANNED=$(( SCRUB_PLANNED + n ))
    return 0
  fi
  while IFS= read -r item <&5; do
    if "$fn" "$item"; then ok=$(( ok + 1 )); else bad=$(( bad + 1 )); fi
  done 5< <(jq -c '.[]' <<<"$items")
  echo "  ${label}: deleted ${ok}"
  if (( bad > 0 )); then print_warn "  ${label}: ${bad} could not be deleted"; fi
  SCRUB_DELETED=$(( SCRUB_DELETED + ok ))
  SCRUB_FAILED=$(( SCRUB_FAILED + bad ))
  return 0
}

_scrub_vars() { # _scrub_vars <item json> → {a: account, id: item id}
  jq -c --argjson a "$SCRUB_ACCOUNT" '{a: $a, id: .id}' <<<"$1"
}

# ── delete callbacks (one item each) ───────────
_del_wfa_schedule() {
  _scrub_ok "schedule $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { workflowAutomationDeleteSchedule(accountId: $a, schedule: {id: $id}) { scheduleId } }' "$(_scrub_vars "$1")")"
}
_del_wfa_definition() {
  _scrub_ok "definition $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($s: String!, $n: String!) { workflowAutomationDeleteWorkflowDefinition(definition: {name: $n}, scope: {id: $s, type: ACCOUNT}) { definition { name } } }' \
    "$(jq -c --arg s "$SCRUB_ACCOUNT" '{s: $s, n: .name}' <<<"$1")")"
}
_del_ai_workflow() {
  _scrub_ok "alert workflow $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { aiWorkflowsDeleteWorkflow(accountId: $a, id: $id, deleteChannels: true) { id errors { description type } } }' "$(_scrub_vars "$1")")" \
    '[.data.aiWorkflowsDeleteWorkflow.errors[]?.description] | join("; ") | select(. != "")'
}
_del_channel() {
  _scrub_ok "channel $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { aiNotificationsDeleteChannel(accountId: $a, channelId: $id) { ids error { description details } } }' "$(_scrub_vars "$1")")" \
    '.data.aiNotificationsDeleteChannel.error.description'
}
_del_destination() {
  _scrub_ok "destination $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { aiNotificationsDeleteDestination(accountId: $a, destinationId: $id) { ids error { description details } } }' "$(_scrub_vars "$1")")" \
    '.data.aiNotificationsDeleteDestination.error.description'
}
_del_muting_rule() {
  _scrub_ok "muting rule $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { alertsMutingRuleDelete(accountId: $a, id: $id) { id } }' "$(_scrub_vars "$1")")"
}
_del_policy() {
  _scrub_ok "policy $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { alertsPolicyDelete(accountId: $a, id: $id) { id } }' "$(_scrub_vars "$1")")"
}
_resolve_issue() {
  _scrub_ok "issue $(jq -r .id <<<"$1")" "$(_scrub_mut 'mutation($a: Int!, $id: ID!) { aiIssuesResolveIssue(accountId: $a, issueId: $id) { error result { issueId } } }' "$(_scrub_vars "$1")")" \
    '.data.aiIssuesResolveIssue.error'
}
_del_dashboard() {
  _scrub_ok "dashboard $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($g: EntityGuid!) { dashboardDelete(guid: $g) { status errors { description type } } }' "$(jq -c '{g: .id}' <<<"$1")")" \
    '[.data.dashboardDelete.errors[]?.description] | join("; ") | select(. != "")'
}
_del_monitor() {
  _scrub_ok "monitor $(jq -r .name <<<"$1")" "$(_scrub_mut 'mutation($g: EntityGuid!) { syntheticsDeleteMonitor(guid: $g) { deletedGuid } }' "$(jq -c '{g: .id}' <<<"$1")")"
}

# _scrub_entities <entities json [{id: guid, name, type, domain}]> → force-delete in batches.
# An APM application that entityDelete rejects is retried with agentApplicationDelete(force).
_scrub_entities() {
  local items="$1" n batch start=0 result failures f guid ok=0 bad=0
  n=$(jq 'length' <<<"$items")
  if [[ "$n" == 0 ]]; then
    echo "  entities: none"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    echo "  entities: would force-delete ${n}: $(jq -r '[.[] | "\(.name) (\(.domain)/\(.type))"] | .[:8] | join(", ")' <<<"$items")$(if (( n > 8 )); then echo ', ...'; fi)"
    SCRUB_PLANNED=$(( SCRUB_PLANNED + n ))
    return 0
  fi
  while (( start < n )); do
    batch=$(jq -c --argjson s "$start" --argjson k "$SCRUB_ENTITY_BATCH" '[.[$s:$s+$k][] | .id]' <<<"$items")
    result=$(_scrub_mut 'mutation($g: [EntityGuid!]!) { entityDelete(guids: $g, forceDelete: true) { deletedEntities failures { guid message type } } }' \
      "$(jq -c -n --argjson g "$batch" '{g: $g}')")
    if ! _scrub_ok "entity batch" "$result"; then
      bad=$(( bad + $(jq 'length' <<<"$batch") ))
    else
      ok=$(( ok + $(jq '(.data.entityDelete.deletedEntities // []) | length' <<<"$result") ))
      failures=$(jq -c '.data.entityDelete.failures // []' <<<"$result")
      while IFS= read -r f <&6; do
        guid=$(jq -r .guid <<<"$f")
        if jq -e --arg g "$guid" 'any(.[]; .id == $g and .domain == "APM" and .type == "APPLICATION")' <<<"$items" >/dev/null; then
          if _scrub_ok "APM app ${guid}" "$(_scrub_mut 'mutation($g: EntityGuid!) { agentApplicationDelete(guid: $g, force: true) { success } }' "$(jq -c -n --arg g "$guid" '{g: $g}')")" \
               'if .data.agentApplicationDelete.success == false then "not deleted" else empty end'; then
            ok=$(( ok + 1 )); continue
          fi
        else
          print_warn "    entity ${guid}: $(jq -r '.message // .type // "failed"' <<<"$f")"
        fi
        bad=$(( bad + 1 ))
      done 6< <(jq -c '.[]' <<<"$failures")
    fi
    start=$(( start + SCRUB_ENTITY_BATCH ))
  done
  echo "  entities: deleted ${ok}"
  if (( bad > 0 )); then print_warn "  entities: ${bad} could not be deleted"; fi
  SCRUB_DELETED=$(( SCRUB_DELETED + ok ))
  SCRUB_FAILED=$(( SCRUB_FAILED + bad ))
}

# _scrub_user_keys <keys json [{id, name, userId}]> → one apiAccessDeleteKeys call
_scrub_user_keys() {
  local items="$1" n result
  n=$(jq 'length' <<<"$items")
  if [[ "$n" == 0 ]]; then
    echo "  user keys: none"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    echo "  user keys: would delete ${n}: $(jq -r '[.[] | "\(.name // "unnamed") (user \(.userId))"] | join(", ")' <<<"$items")"
    SCRUB_PLANNED=$(( SCRUB_PLANNED + n ))
    return 0
  fi
  result=$(_scrub_mut 'mutation($ids: [String!]!) { apiAccessDeleteKeys(keys: {userKeyIds: $ids}) { deletedKeys { id } errors { message } } }' \
    "$(jq -c '{ids: [.[].id]}' <<<"$items")")
  if _scrub_ok "user keys" "$result" '[.data.apiAccessDeleteKeys.errors[]?.message] | join("; ") | select(. != "")'; then
    echo "  user keys: deleted ${n}"
    SCRUB_DELETED=$(( SCRUB_DELETED + n ))
  else
    SCRUB_FAILED=$(( SCRUB_FAILED + n ))
  fi
}

# _scrub_step <label> <list result or empty on failure> <delete function>
_scrub_step() {
  if [[ -z "$2" ]]; then
    print_warn "  $1: skipped (listing failed)"
    SCRUB_FAILED=$(( SCRUB_FAILED + 1 ))
    return 0
  fi
  _scrub_each "$1" "$2" "$3"
}

# scrub_account <account id> → 0 when everything listed was deleted (or would be, in a dry run).
# Refuses any account whose name is not "<LAB_ACCOUNT_PREFIX> <digits>".
scrub_account() {
  local id="$1" accounts name re me pool list v now from all
  SCRUB_ACCOUNT="$id"
  SCRUB_DELETED=0
  SCRUB_FAILED=0
  SCRUB_PLANNED=0
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    print_err "scrub: account id '$id' is not numeric"
    return 1
  fi
  accounts=$(fetch_accounts) || return 1
  name=$(jq -r --arg id "$id" '[.[] | select((.id | tostring) == $id)] | first | .name // empty' <<<"$accounts")
  re="^${LAB_ACCOUNT_PREFIX} [0-9]+\$"
  if [[ -z "$name" ]] || ! [[ "$name" =~ $re ]]; then
    print_err "scrub: refusing account ${id} ('${name:-not visible to this key}'): only '${LAB_ACCOUNT_PREFIX} NN' lab accounts are scrubbed"
    return 1
  fi
  echo "  scrubbing '${name}' (id ${id})$([[ "${DRY_RUN:-0}" == 1 ]] && echo ', dry run')"
  v=$(jq -c -n --argjson a "$id" '{a: $a}')

  # 1. Workflow Automation: schedules, then definitions (account scope only)
  list=$(_scrub_list 'query($a: Int!) { actor { account(id: $a) { workflowAutomation { schedules { results { schedule { id } definition { name } } } } } } }' \
    "$v" '.data.actor.account.workflowAutomation.schedules.results') && \
    list=$(jq -c '[.[] | {id: .schedule.id, name: (.definition.name // .schedule.id)}]' <<<"$list") || list=""
  _scrub_step "Workflow Automation schedules" "$list" _del_wfa_schedule
  list=$(_scrub_list 'query($a: Int!, $cursor: String) { actor { account(id: $a) { workflowAutomation { workflows(cursor: $cursor) { nextCursor results { definition { name scope { id type } } } } } } } }' \
    "$v" '.data.actor.account.workflowAutomation.workflows.results' '.data.actor.account.workflowAutomation.workflows.nextCursor') && \
    list=$(jq -c '[.[] | .definition | select((.scope.type // "ACCOUNT") == "ACCOUNT") | .name] | unique | map({id: ., name: .})' <<<"$list") || list=""
  _scrub_step "Workflow Automation definitions" "$list" _del_wfa_definition

  # 2-3. Alert workflows (and their channels), then any remaining channels and destinations
  list=$(_scrub_list 'query($a: Int!, $cursor: String) { actor { account(id: $a) { aiWorkflows { workflows(cursor: $cursor) { nextCursor entities { id name } } } } } }' \
    "$v" '.data.actor.account.aiWorkflows.workflows.entities' '.data.actor.account.aiWorkflows.workflows.nextCursor') || list=""
  _scrub_step "alert workflows" "$list" _del_ai_workflow
  list=$(_scrub_list 'query($a: Int!, $cursor: String) { actor { account(id: $a) { aiNotifications { channels(cursor: $cursor) { nextCursor entities { id name } } } } } }' \
    "$v" '.data.actor.account.aiNotifications.channels.entities' '.data.actor.account.aiNotifications.channels.nextCursor') || list=""
  _scrub_step "notification channels" "$list" _del_channel
  list=$(_scrub_list 'query($a: Int!, $cursor: String) { actor { account(id: $a) { aiNotifications { destinations(cursor: $cursor) { nextCursor entities { id name } } } } } }' \
    "$v" '.data.actor.account.aiNotifications.destinations.entities' '.data.actor.account.aiNotifications.destinations.nextCursor') || list=""
  _scrub_step "destinations" "$list" _del_destination

  # 4. Muting rules, then policies (a policy delete removes its conditions)
  list=$(_scrub_list 'query($a: Int!) { actor { account(id: $a) { alerts { mutingRules { id name } } } } }' \
    "$v" '.data.actor.account.alerts.mutingRules') || list=""
  _scrub_step "muting rules" "$list" _del_muting_rule
  list=$(_scrub_list 'query($a: Int!, $cursor: String) { actor { account(id: $a) { alerts { policiesSearch(cursor: $cursor) { nextCursor policies { id name } } } } } }' \
    "$v" '.data.actor.account.alerts.policiesSearch.policies' '.data.actor.account.alerts.policiesSearch.nextCursor') || list=""
  _scrub_step "alert policies" "$list" _del_policy

  # 5. Issues still open
  now=$(( $(date +%s) * 1000 ))
  from=$(( now - SCRUB_ISSUE_DAYS * 86400000 ))
  list=$(_scrub_list 'query($a: Int!, $from: EpochMilliseconds!, $to: EpochMilliseconds!, $cursor: String) { actor { account(id: $a) { aiIssues { issues(cursor: $cursor, filter: {states: [ACTIVATED, CREATED]}, timeWindow: {startTime: $from, endTime: $to}) { nextCursor issues { issueId } } } } } }' \
    "$(jq -c -n --argjson a "$id" --argjson f "$from" --argjson t "$now" '{a: $a, from: $f, to: $t}')" \
    '.data.actor.account.aiIssues.issues.issues' '.data.actor.account.aiIssues.issues.nextCursor') && \
    list=$(jq -c '[.[] | {id: .issueId}]' <<<"$list") || list=""
  _scrub_step "open issues" "$list" _resolve_issue

  # 6-7. Entities: dashboards (top level only, pages go with them), monitors, then everything else
  all=$(_scrub_list 'query($q: String!, $cursor: String) { actor { entitySearch(query: $q) { results(cursor: $cursor) { nextCursor entities { guid name type domain ... on DashboardEntityOutline { dashboardParentGuid } } } } } }' \
    "$(jq -c -n --arg q "accountId = ${id}" '{q: $q}')" \
    '.data.actor.entitySearch.results.entities' '.data.actor.entitySearch.results.nextCursor') || all=""
  if [[ -z "$all" ]]; then
    print_warn "  entities: skipped (listing failed)"
    SCRUB_FAILED=$(( SCRUB_FAILED + 1 ))
  else
    all=$(jq -c '[.[] | {id: .guid, name, type, domain, parent: (.dashboardParentGuid // null)}]' <<<"$all")
    _scrub_each "dashboards" "$(jq -c '[.[] | select(.type == "DASHBOARD" and .parent == null)]' <<<"$all")" _del_dashboard
    _scrub_each "synthetic monitors" "$(jq -c '[.[] | select(.domain == "SYNTH" and .type == "MONITOR")]' <<<"$all")" _del_monitor
    _scrub_entities "$(jq -c '[.[] | select(.type != "DASHBOARD" and .domain != "AIOPS" and (.domain == "SYNTH" and .type == "MONITOR" | not))]' <<<"$all")"
  fi

  # 8. USER keys on the account owned by pool users (never the caller's, never an instructor's)
  me=$(jq -r '.data.actor.user.id // empty' <<<"$(gql '{"query": "{ actor { user { id } } }"}')" 2>/dev/null || true)
  pool=""
  if [[ -n "${NR_AUTH_DOMAIN_ID:-}" ]] || resolve_context >/dev/null 2>&1; then
    pool=$(fetch_users 2>/dev/null | jq -c '[.[].id | tostring]' 2>/dev/null || true)
  fi
  if [[ -z "$pool" ]]; then
    print_warn "  user keys: skipped (could not list the pool users)"
    SCRUB_FAILED=$(( SCRUB_FAILED + 1 ))
  else
    list=$(_scrub_list 'query($a: Int!, $cursor: String) { actor { apiAccess { keySearch(cursor: $cursor, query: {types: [USER], scope: {accountIds: [$a]}}) { nextCursor keys { id name ... on ApiAccessUserKey { userId } } } } } }' \
      "$v" '.data.actor.apiAccess.keySearch.keys' '.data.actor.apiAccess.keySearch.nextCursor') && \
      list=$(jq -c --arg me "$me" --argjson pool "$pool" \
        '[.[] | select(.userId != null) | (.userId | tostring) as $u | select($u != $me and ($pool | index($u)) != null) | {id, name, userId}]' <<<"$list") || list=""
    if [[ -z "$list" ]]; then
      print_warn "  user keys: skipped (listing failed)"
      SCRUB_FAILED=$(( SCRUB_FAILED + 1 ))
    else
      _scrub_user_keys "$list"
    fi
  fi

  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    echo "  dry run: ${SCRUB_PLANNED} object(s) would be deleted$( (( SCRUB_FAILED > 0 )) && echo ", ${SCRUB_FAILED} listing(s) failed")"
  else
    echo "  deleted ${SCRUB_DELETED} object(s), ${SCRUB_FAILED} failure(s)"
  fi
  (( SCRUB_FAILED == 0 ))
}
