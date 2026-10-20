#!/usr/bin/env python3
"""Create the lab's alerting and Workflow Automation chain through NerdGraph.

Ported from the AWS GameDay bootstrap Lambda (same mutations, same order), remapped to this lab.
Every step is find-or-create by name, so re-running is safe and check scripts can reuse it.

  policy       alert policy plus the shop-api NRQL conditions
  destination  email destination and Workflow Automation destination
  definition   upload a Workflow Automation definition from a YAML file
  channel      Workflow Automation channel, bound to one version of a definition (challenge 04)
  workflow     alert Workflow: issues from the policy -> its own email channel, plus the
               Workflow Automation channel that `channel` created (unless --email-only)
  all          policy, destination, [definition], channel, workflow
  status       read-only: which pieces exist

Credentials come from the environment or ../.env: NEW_RELIC_API_KEY, NEW_RELIC_ACCOUNT_ID.
--dry-run prints each mutation's variables (API key masked) and changes nothing.
Standard library only. No prompts: a missing value is an error, so it is safe in setup scripts.

A notification channel can belong to only one alert Workflow, so each alert Workflow gets its own
email channel, named after it. Destinations are shared.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

NERDGRAPH = "https://api.newrelic.com/graphql"
APP = "wfa-shop-api"

DEFAULTS = {
    "policy": "Workflow Automation - Shop API",
    "email_destination": "Lab - Email",
    "wfa_destination": "Lab - Workflow Automation",
    "wfa_channel": "Lab - Remediation Channel",
    "workflow": "Shop API - Auto-Remediation",
    "definition": "shop_api_error_rollback",
}

# Thresholds from live data, account 8081107, 2026-10-19 (3-minute buckets):
#   error rate  v1 0%,      v2 21 to 56%
#   p95         v1 ~5 ms,   v2 3.8 to 4.4 s
#   cache miss  v1 5%,      v2 100% (on /api/products)
CONDITIONS = {
    "error-rate": {
        "name": "Shop API - High Error Rate",
        # Same shape as the condition built by hand in the UI, scoped by name instead of a GUID.
        "query": "SELECT sum(apm.service.error.count['count']) / count(apm.service.transaction.duration) * 100 "
                 f"AS 'Error rate' FROM Metric WHERE appName = '{APP}'",
        "threshold": 20,
    },
    "latency": {
        "name": "Shop API - High Latency",
        "query": f"SELECT percentile(duration, 95) FROM Transaction WHERE appName = '{APP}'",
        "threshold": 2,
    },
    "cache-miss": {
        "name": "Shop API - High Cache Miss Rate",
        "query": "SELECT percentage(count(*), WHERE app.cache_hit = false) FROM Transaction "
                 f"WHERE appName = '{APP}' AND app.cache_hit IS NOT NULL",
        "threshold": 30,
    },
}

DRY_RUN = False


class BootstrapError(Exception):
    pass


# ---- plumbing ----------------------------------------------------------------

def load_env():
    """Fill missing variables from ../.env without overriding the real environment."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key, value)


def credentials(args):
    key = os.environ.get("NEW_RELIC_API_KEY", "")
    account = args.account_id or os.environ.get("NEW_RELIC_ACCOUNT_ID", "")
    if not key.startswith("NRAK-"):
        raise BootstrapError("NEW_RELIC_API_KEY (NRAK-...) is not set. Run ./lab/wire-credentials.sh")
    if not str(account).isdigit():
        raise BootstrapError("NEW_RELIC_ACCOUNT_ID is not set or not numeric")
    return key, int(account)


def masked(value):
    if isinstance(value, dict):
        return {k: masked(v) for k, v in value.items()}
    if isinstance(value, list):
        return [masked(v) for v in value]
    if isinstance(value, str) and value.startswith("NRAK-"):
        return "NRAK-****"
    return value


def nerdgraph(key, query, variables=None):
    req = urllib.request.Request(
        NERDGRAPH, data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={"Content-Type": "application/json", "API-Key": key})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise BootstrapError(f"NerdGraph HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise BootstrapError(f"NerdGraph unreachable: {e.reason}") from None
    if body.get("errors"):
        raise BootstrapError("NerdGraph: " + "; ".join(e.get("message", "") for e in body["errors"]))
    return body["data"]


def mutate(key, label, query, variables, path, hint=None, hint_text=""):
    """Run a create mutation and return the object at `path`; in dry-run mode just print it."""
    if DRY_RUN:
        print(f"  [dry-run] {label}: {json.dumps(masked(variables), indent=2)}")
        return {"id": f"<{label}>"}
    data = nerdgraph(key, query, variables)
    result = data
    for part in path[:-1]:
        result = result[part]
    errors = result.get("errors")
    if errors:
        message = f"{label} failed: {json.dumps(errors)}"
        if hint and hint in message:
            message += f"\n  {hint_text}"
        raise BootstrapError(message)
    return result[path[-1]]


def account_query(key, account, fragment, variables=None):
    if DRY_RUN:
        return None
    data = nerdgraph(key, f"query($accountId: Int!{variables_decl(variables)}) "
                          f"{{ actor {{ account(id: $accountId) {{ {fragment} }} }} }}",
                     {"accountId": account, **(variables or {})})
    return data["actor"]["account"]


def variables_decl(variables):
    types = {"name": "String!", "policyId": "ID!"}
    return "".join(f", ${k}: {types[k]}" for k in (variables or {}))


def report(kind, name, obj_id, created):
    print(f"  {'created' if created else 'exists '} {kind:<24} {name}  ({obj_id})")


# ---- find ---------------------------------------------------------------------

def find_policy(key, account, name):
    acct = account_query(key, account,
                         "alerts { policiesSearch(searchCriteria: {nameLike: $name}) { policies { id name } } }",
                         {"name": name})
    if not acct:
        return None
    return next((p["id"] for p in acct["alerts"]["policiesSearch"]["policies"] if p["name"] == name), None)


def find_conditions(key, account, policy_id):
    acct = account_query(key, account,
                         "alerts { nrqlConditionsSearch(searchCriteria: {policyId: $policyId}) "
                         "{ nrqlConditions { id name } } }", {"policyId": str(policy_id)})
    if not acct:
        return {}
    return {c["name"]: c["id"] for c in acct["alerts"]["nrqlConditionsSearch"]["nrqlConditions"]}


def find_notification(key, account, collection, kind, name):
    acct = account_query(key, account,
                         f"aiNotifications {{ {collection}(filters: {{type: {kind}, name: $name}}) "
                         "{ entities { id name } } }", {"name": name})
    if not acct:
        return None
    entities = acct["aiNotifications"][collection]["entities"]
    return next((e["id"] for e in entities if e["name"] == name), None)


def find_wfa_channel(key, account, definition):
    """The newest Workflow Automation channel bound to `definition`, as (id, name), or None."""
    acct = account_query(key, account,
                         "aiNotifications { channels(filters: {type: WORKFLOW_AUTOMATION}) "
                         "{ entities { id name createdAt properties { key value } } } }")
    if not acct:
        return None
    bound = [c for c in acct["aiNotifications"]["channels"]["entities"]
             if {"key": "workflowAutomation", "value": definition} in
             [{"key": p["key"], "value": p["value"]} for p in c.get("properties") or []]]
    if not bound:
        return None
    newest = max(bound, key=lambda c: c.get("createdAt") or "")
    return newest["id"], newest["name"]


def find_workflow(key, account, name):
    acct = account_query(key, account,
                         "aiWorkflows { workflows(filters: {name: $name}) { entities { id name } } }",
                         {"name": name})
    if not acct:
        return None
    return next((w["id"] for w in acct["aiWorkflows"]["workflows"]["entities"] if w["name"] == name), None)


# ---- create -------------------------------------------------------------------

def ensure_policy(key, account, args):
    policy_id = find_policy(key, account, args.policy)
    if policy_id:
        report("policy", args.policy, policy_id, False)
    else:
        policy_id = mutate(key, "policy", """
            mutation($accountId: Int!, $policy: AlertsPolicyInput!) {
              alertsPolicyCreate(accountId: $accountId, policy: $policy) { id name }
            }""", {"accountId": account,
                   "policy": {"name": args.policy, "incidentPreference": args.incident_preference}},
            ["alertsPolicyCreate"])["id"]
        report("policy", args.policy, policy_id, True)

    existing = find_conditions(key, account, policy_id)
    for slug in args.conditions:
        spec = CONDITIONS[slug]
        if spec["name"] in existing:
            report("condition", spec["name"], existing[spec["name"]], False)
            continue
        condition = {
            "name": spec["name"],
            "enabled": True,
            "nrql": {"query": spec["query"]},
            "signal": {"aggregationWindow": 60, "aggregationMethod": "EVENT_FLOW", "aggregationDelay": 120},
            "terms": [{"priority": "CRITICAL", "operator": "ABOVE", "threshold": spec["threshold"],
                       "thresholdDuration": args.threshold_duration,
                       "thresholdOccurrences": "AT_LEAST_ONCE"}],
            "valueFunction": "SINGLE_VALUE",
            "violationTimeLimitSeconds": 86400,
        }
        created = mutate(key, f"condition {slug}", """
            mutation($accountId: Int!, $policyId: ID!, $condition: AlertsNrqlConditionStaticInput!) {
              alertsNrqlConditionStaticCreate(accountId: $accountId, policyId: $policyId, condition: $condition)
              { id name }
            }""", {"accountId": account, "policyId": str(policy_id), "condition": condition},
            ["alertsNrqlConditionStaticCreate"])
        report("condition", spec["name"], created["id"], True)
    return policy_id


def ensure_destination(key, account, kind, name, destination):
    found = find_notification(key, account, "destinations", kind, name)
    if found:
        report(f"{kind.lower()} destination", name, found, False)
        return found
    created = mutate(key, f"{kind.lower()} destination", """
        mutation($accountId: Int!, $destination: AiNotificationsDestinationInput!) {
          aiNotificationsCreateDestination(accountId: $accountId, destination: $destination) {
            destination { id name }
            errors { ... on AiNotificationsResponseError { description type } }
          }
        }""", {"accountId": account, "destination": {"name": name, "type": kind, **destination}},
        ["aiNotificationsCreateDestination", "destination"])
    report(f"{kind.lower()} destination", name, created["id"], True)
    return created["id"]


def ensure_email_destination(key, account, args):
    # The address is needed only to create the destination; an existing one is reused as is.
    found = find_notification(key, account, "destinations", "EMAIL", args.email_destination)
    if found:
        report("email destination", args.email_destination, found, False)
        return found
    if not args.email:
        raise BootstrapError("--email (or ALERT_EMAIL) is required to create the email destination")
    return ensure_destination(key, account, "EMAIL", args.email_destination,
                              {"properties": [{"key": "email", "value": args.email}]})


def ensure_wfa_destination(key, account, args):
    # Workflow Automation calls back into New Relic with this key. It persists in the account:
    # the learner is told in challenge 04 and cleanup removes it.
    return ensure_destination(key, account, "WORKFLOW_AUTOMATION", args.wfa_destination, {
        "properties": [],
        "auth": {"type": "CUSTOM_HEADERS",
                 "customHeaders": {"customHeaders": [{"key": "Api-Key", "value": key}]}},
    })


def ensure_destinations(key, account, args):
    return ensure_email_destination(key, account, args), ensure_wfa_destination(key, account, args)


# Workflow Automation rejects any other character in a definition's description.
DESCRIPTION_OK = re.compile(r"^[A-Za-z0-9 _-]*$")


def check_definition(yaml_text):
    """Catch what NerdGraph would reject, with a message that says which line to fix."""
    for line in yaml_text.splitlines():
        if line.startswith("description:"):
            value = line.split(":", 1)[1].strip().strip("'\"")
            if not DESCRIPTION_OK.match(value):
                raise BootstrapError(f"description may only use letters, numbers, spaces, '_' and '-': {value!r}")


def ensure_definition(key, account, path):
    with open(path) as f:
        yaml_text = f.read()
    check_definition(yaml_text)
    encoded = base64.b64encode(yaml_text.encode()).decode()
    if DRY_RUN:
        print(f"  [dry-run] definition: upload {path} ({len(yaml_text)} bytes) to account {account}")
        return
    # The scope and definition input types are not confirmed yet, so this keeps the Lambda's
    # inline form. Both values are safe to inline: a number and a base64 string.
    try:
        nerdgraph(key, f"""
            mutation {{
              workflowAutomationCreateWorkflowDefinition(
                scope: {{ id: "{account}" }}
                definition: {{ yaml: "{encoded}" }}
              ) {{ definition {{ name }} }}
            }}""")
        report("definition", path, "uploaded", True)
    except BootstrapError as e:
        if "already exists" not in str(e):
            raise
        report("definition", path, "already exists", False)


def ensure_channel(key, account, kind, name, destination_id, properties):
    found = find_notification(key, account, "channels", kind, name)
    if found:
        report(f"{kind.lower()} channel", name, found, False)
        return found
    created = mutate(key, f"{kind.lower()} channel", """
        mutation($accountId: Int!, $channel: AiNotificationsChannelInput!) {
          aiNotificationsCreateChannel(accountId: $accountId, channel: $channel) {
            channel { id name }
            errors { ... on AiNotificationsResponseError { description type } }
          }
        }""", {"accountId": account, "channel": {
            "name": name, "type": kind, "product": "IINT",
            "destinationId": destination_id, "properties": properties}},
        ["aiNotificationsCreateChannel", "channel"])
    report(f"{kind.lower()} channel", name, created["id"], True)
    return created["id"]


def ensure_email_channel(key, account, args):
    email_dest = ensure_email_destination(key, account, args)
    return ensure_channel(key, account, "EMAIL", args.email_channel, email_dest,
                          [{"key": "subject", "value": "{{ issueTitle }}"}])


def ensure_wfa_channel(key, account, args):
    # workflowAutomation must equal the definition's `name`. A canvas edit creates a new version,
    # so this pin needs a sync step later (Workplan-Bootstrap 6.2, BQ8).
    version = args.definition_version or 1
    name = args.wfa_channel or f"{DEFAULTS['wfa_channel']} v{version}"
    wfa_dest = ensure_wfa_destination(key, account, args)
    return ensure_channel(key, account, "WORKFLOW_AUTOMATION", name, wfa_dest, [
        {"key": "workflowAutomation", "value": args.definition},
        {"key": "workflowAutomationVersion", "value": str(version)},
        {"key": "workflowAutomationLogLevel", "value": "TRACE"},
    ])


def existing_wfa_channel(key, account, args):
    """Reuse the channel challenge 04 created, so challenge 05 needs no version number."""
    if DRY_RUN:
        report("workflow_automation channel", f"newest bound to {args.definition}", "<lookup>", False)
        return "<workflow_automation channel>"
    found = find_wfa_channel(key, account, args.definition)
    if not found:
        raise BootstrapError(f"no Workflow Automation channel is bound to {args.definition}. "
                             "Run `wfa_bootstrap.py channel --definition-version <N>` first (challenge 04, Step 12)")
    report("workflow_automation channel", found[1], found[0], False)
    return found[0]


def ensure_workflow(key, account, args, policy_id, channel_ids):
    found = find_workflow(key, account, args.workflow)
    if found:
        report("alert workflow", args.workflow, found, False)
        return found
    created = mutate(key, "alert workflow", """
        mutation($accountId: Int!, $workflow: AiWorkflowsCreateWorkflowInput!) {
          aiWorkflowsCreateWorkflow(accountId: $accountId, createWorkflowData: $workflow) {
            workflow { id name }
            errors { description type }
          }
        }""", {"accountId": account, "workflow": {
            "name": args.workflow,
            "workflowEnabled": True,
            "destinationsEnabled": True,
            "mutingRulesHandling": "DONT_NOTIFY_FULLY_MUTED_ISSUES",
            "issuesFilter": {"name": "policy", "type": "FILTER", "predicates": [
                {"attribute": "labels.policyIds", "operator": "EXACTLY_MATCHES", "values": [str(policy_id)]}]},
            # Acknowledge is a manual fallback: acknowledging the issue starts the workflow again.
            "destinationConfigurations": [{"channelId": c, "notificationTriggers": ["ACTIVATED", "ACKNOWLEDGED"]}
                                          for c in channel_ids],
        }}, ["aiWorkflowsCreateWorkflow", "workflow"], hint="already in use",
        hint_text="A channel can belong to only one alert workflow. Pass a different --email-channel, "
                  "or delete the alert workflow that holds it")
    report("alert workflow", args.workflow, created["id"], True)
    return created["id"]


# ---- commands -----------------------------------------------------------------

def cmd_policy(key, account, args):
    ensure_policy(key, account, args)


def cmd_destination(key, account, args):
    ensure_destinations(key, account, args)


def cmd_definition(key, account, args):
    if not args.file:
        raise BootstrapError("--file is required")
    ensure_definition(key, account, args.file)


def cmd_channel(key, account, args):
    ensure_wfa_channel(key, account, args)


def cmd_workflow(key, account, args):
    policy_id = ensure_policy(key, account, args)
    channels = [ensure_email_channel(key, account, args)]
    if not args.email_only:
        # An explicit version or channel name creates that channel; otherwise reuse challenge 04's.
        if args.definition_version or args.wfa_channel:
            channels.append(ensure_wfa_channel(key, account, args))
        else:
            channels.append(existing_wfa_channel(key, account, args))
    ensure_workflow(key, account, args, policy_id, channels)


def cmd_all(key, account, args):
    if args.file:
        ensure_definition(key, account, args.file)
    args.definition_version = args.definition_version or 1
    cmd_workflow(key, account, args)


def cmd_status(key, account, args):
    global DRY_RUN
    DRY_RUN = False
    policy_id = find_policy(key, account, args.policy)
    print(f"  policy               {args.policy}: {policy_id or 'missing'}")
    if policy_id:
        conditions = find_conditions(key, account, policy_id)
        for slug in args.conditions:
            name = CONDITIONS[slug]["name"]
            print(f"  condition            {name}: {conditions.get(name, 'missing')}")
    for label, collection, kind, name in (
            ("email destination", "destinations", "EMAIL", args.email_destination),
            ("wfa destination", "destinations", "WORKFLOW_AUTOMATION", args.wfa_destination),
            ("email channel", "channels", "EMAIL", args.email_channel)):
        print(f"  {label:<20} {name}: {find_notification(key, account, collection, kind, name) or 'missing'}")
    wfa = find_wfa_channel(key, account, args.definition)
    print(f"  wfa channel          bound to {args.definition}: {f'{wfa[1]} ({wfa[0]})' if wfa else 'missing'}")
    print(f"  alert workflow       {args.workflow}: {find_workflow(key, account, args.workflow) or 'missing'}")


COMMANDS = {"policy": cmd_policy, "destination": cmd_destination, "definition": cmd_definition,
            "channel": cmd_channel, "workflow": cmd_workflow, "all": cmd_all, "status": cmd_status}


def parse(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("command", choices=COMMANDS)
    p.add_argument("--account-id", help="defaults to NEW_RELIC_ACCOUNT_ID")
    p.add_argument("--dry-run", action="store_true", help="print mutations, change nothing")
    p.add_argument("--policy", default=DEFAULTS["policy"])
    p.add_argument("--incident-preference", default="PER_CONDITION",
                   choices=["PER_POLICY", "PER_CONDITION", "PER_CONDITION_AND_TARGET"])
    p.add_argument("--conditions", default="error-rate,latency",
                   type=lambda s: [c for c in s.split(",") if c],
                   help=f"comma list from: {', '.join(CONDITIONS)}")
    p.add_argument("--threshold-duration", type=int, default=120, help="seconds above threshold")
    p.add_argument("--email", default=os.environ.get("ALERT_EMAIL", ""))
    p.add_argument("--email-only", action="store_true", help="alert workflow routes to email only (challenge 02)")
    p.add_argument("--email-destination", default=DEFAULTS["email_destination"])
    p.add_argument("--wfa-destination", default=DEFAULTS["wfa_destination"])
    p.add_argument("--email-channel", help="default: '<workflow> - Email', one per alert workflow")
    p.add_argument("--wfa-channel", help="default: 'Lab - Remediation Channel v<N>'")
    p.add_argument("--workflow", default=DEFAULTS["workflow"])
    p.add_argument("--definition", default=DEFAULTS["definition"], help="Workflow Automation definition name")
    p.add_argument("--definition-version", type=int,
                   help="`channel`: the version to bind (default 1). `workflow`: omit to reuse that channel")
    p.add_argument("--file", help="definition YAML for `definition` / `all`")
    args = p.parse_args(argv)
    args.email_channel = args.email_channel or f"{args.workflow} - Email"
    unknown = [c for c in args.conditions if c not in CONDITIONS]
    if unknown:
        p.error(f"unknown condition(s): {', '.join(unknown)}")
    return args


def main(argv=None):
    global DRY_RUN
    load_env()
    args = parse(argv)
    DRY_RUN = args.dry_run
    try:
        if DRY_RUN:
            key = os.environ.get("NEW_RELIC_API_KEY") or "NRAK-DRYRUN"
            account = int(args.account_id or os.environ.get("NEW_RELIC_ACCOUNT_ID") or 0)
        else:
            key, account = credentials(args)
        print(f"{args.command} (account {account}{', dry run' if DRY_RUN else ''})")
        COMMANDS[args.command](key, account, args)
    except BootstrapError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
