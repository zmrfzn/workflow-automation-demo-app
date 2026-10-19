"""wfa_bootstrap: find-or-create logic, with NerdGraph replaced by a fake account."""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lab"))
import wfa_bootstrap as wb  # noqa: E402


class FakeAccount:
    """Answers the script's queries from in-memory state and records every mutation."""

    def __init__(self):
        self.policies, self.conditions, self.destinations, self.channels, self.workflows = {}, {}, {}, {}, {}
        self.mutations = []

    def __call__(self, key, query, variables=None):
        v = variables or {}
        if "mutation" in query:
            self.mutations.append(query)
            return self.create(query, v)
        account = {}
        if "policiesSearch" in query:
            account["alerts"] = {"policiesSearch": {"policies": [
                {"id": i, "name": n} for n, i in self.policies.items()]}}
        elif "nrqlConditionsSearch" in query:
            account["alerts"] = {"nrqlConditionsSearch": {"nrqlConditions": [
                {"id": i, "name": n} for n, i in self.conditions.items()]}}
        elif "destinations(" in query:
            account["aiNotifications"] = {"destinations": {"entities": [
                {"id": i, "name": n} for n, i in self.destinations.items() if n == v["name"]]}}
        elif "channels(" in query:
            account["aiNotifications"] = {"channels": {"entities": [
                {"id": i, "name": n} for n, i in self.channels.items() if n == v["name"]]}}
        elif "workflows(" in query:
            account["aiWorkflows"] = {"workflows": {"entities": [
                {"id": i, "name": n} for n, i in self.workflows.items() if n == v["name"]]}}
        return {"actor": {"account": account}}

    def create(self, query, v):
        if "alertsPolicyCreate" in query:
            self.policies[v["policy"]["name"]] = "p1"
            return {"alertsPolicyCreate": {"id": "p1"}}
        if "alertsNrqlConditionStaticCreate" in query:
            cid = f"c{len(self.conditions) + 1}"
            self.conditions[v["condition"]["name"]] = cid
            return {"alertsNrqlConditionStaticCreate": {"id": cid}}
        if "aiNotificationsCreateDestination" in query:
            did = f"d{len(self.destinations) + 1}"
            self.destinations[v["destination"]["name"]] = did
            return {"aiNotificationsCreateDestination": {"destination": {"id": did}, "errors": []}}
        if "aiNotificationsCreateChannel" in query:
            cid = f"ch{len(self.channels) + 1}"
            self.channels[v["channel"]["name"]] = cid
            return {"aiNotificationsCreateChannel": {"channel": {"id": cid}, "errors": []}}
        if "aiWorkflowsCreateWorkflow" in query:
            self.workflow_input = v["workflow"]
            self.workflows[v["workflow"]["name"]] = "w1"
            return {"aiWorkflowsCreateWorkflow": {"workflow": {"id": "w1"}, "errors": []}}
        raise AssertionError("unexpected mutation")


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeAccount()
        env = {"NEW_RELIC_API_KEY": "NRAK-TEST", "NEW_RELIC_ACCOUNT_ID": "8081107"}
        self.patches = [mock.patch.object(wb, "nerdgraph", self.fake),
                        mock.patch.object(wb, "load_env", lambda: None),
                        mock.patch.dict(os.environ, env)]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def run_cli(self, *argv):
        with mock.patch("sys.stdout"):
            return wb.main(list(argv))

    def test_workflow_creates_the_whole_chain(self):
        self.assertEqual(self.run_cli("workflow", "--email", "a@example.com"), 0)
        self.assertEqual(len(self.fake.policies), 1)
        self.assertEqual(set(self.fake.conditions), {"Shop API - High Error Rate", "Shop API - High Latency"})
        self.assertEqual(len(self.fake.destinations), 2)
        self.assertEqual(len(self.fake.channels), 2)
        wf = self.fake.workflow_input
        self.assertEqual(wf["issuesFilter"]["predicates"][0]["values"], ["p1"])
        self.assertEqual(len(wf["destinationConfigurations"]), 2)

    def test_rerun_creates_nothing(self):
        self.run_cli("workflow", "--email", "a@example.com")
        before = len(self.fake.mutations)
        self.assertEqual(self.run_cli("workflow", "--email", "a@example.com"), 0)
        self.assertEqual(len(self.fake.mutations), before)

    def test_email_only_routes_to_one_channel(self):
        self.run_cli("workflow", "--email", "a@example.com", "--email-only")
        self.assertEqual(len(self.fake.workflow_input["destinationConfigurations"]), 1)

    def test_conditions_target_the_shop_api_by_name(self):
        for spec in wb.CONDITIONS.values():
            self.assertIn("appName = 'wfa-shop-api'", spec["query"])

    def test_missing_email_fails_cleanly(self):
        with mock.patch("sys.stderr"):
            self.assertEqual(self.run_cli("destination"), 1)
        self.assertEqual(self.fake.mutations, [])

    def test_missing_key_fails_cleanly(self):
        with mock.patch.dict(os.environ, {"NEW_RELIC_API_KEY": ""}), mock.patch("sys.stderr"):
            self.assertEqual(self.run_cli("status"), 1)

    def test_shipped_definitions_pass_the_description_rule(self):
        root = os.path.join(os.path.dirname(__file__), "..", "workflows")
        for name in os.listdir(root):
            with open(os.path.join(root, name)) as f:
                wb.check_definition(f.read())

    def test_description_with_punctuation_is_rejected(self):
        with self.assertRaises(wb.BootstrapError):
            wb.check_definition("name: x\ndescription: Roll back when high.\n")


if __name__ == "__main__":
    unittest.main()
