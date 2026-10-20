import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "controller"))
os.environ["ROLLBACK_SECRET"] = "test-secret"
os.environ.pop("NEW_RELIC_API_KEY", None)

import controller  # noqa: E402

AUTH = {"X-Rollback-Token": "test-secret"}
REAL_COMPOSE_UP = controller.compose_up  # captured before any test patches it


class Cluster:
    """Pretends to be Docker: compose_up changes which release answers."""
    def __init__(self, version="v2"):
        self.version = version
        self.ups = []

    def compose_up(self, v):
        self.ups.append(v)
        self.version = v

    def get_version(self):
        return self.version


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.cluster = Cluster("v2")
        controller._history.clear()
        patches = [
            mock.patch.object(controller, "compose_up", self.cluster.compose_up),
            mock.patch.object(controller, "get_version", self.cluster.get_version),
            mock.patch.object(controller, "flush_cache", lambda: True),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.client = controller.app.test_client()

    def test_writes_require_the_token(self):
        for path in ("/rollback", "/deploy", "/reset"):
            self.assertEqual(self.client.post(path).status_code, 401, path)
            self.assertEqual(self.client.post(path, headers={"X-Rollback-Token": "wrong"}).status_code, 401)
        self.assertEqual(self.cluster.ups, [])

    def test_fails_closed_without_a_configured_secret(self):
        with mock.patch.dict(os.environ, {"ROLLBACK_SECRET": ""}):
            self.assertEqual(self.client.post("/rollback", headers=AUTH).status_code, 503)

    def test_rollback_moves_v2_to_v1_and_verifies(self):
        body = self.client.post("/rollback", headers=AUTH, json={"reason": "errors"}).get_json()
        self.assertEqual((body["version_before"], body["version_after"]), ("v2", "v1"))
        self.assertTrue(body["verified"])
        self.assertFalse(body["noop"])
        self.assertEqual(self.cluster.ups, ["v1"])
        self.assertTrue(body["nr_marker"]["skipped"])  # no API key in tests

    def test_marker_records_who_triggered_the_change(self):
        sent = {}

        def fake_nerdgraph(query, variables):
            sent.update(variables)
            return {"changeTrackingCreateDeployment": {"deploymentId": "d1"}}

        with mock.patch.dict(os.environ, {"NEW_RELIC_API_KEY": "NRAK-TEST"}), \
                mock.patch.object(controller, "nerdgraph", fake_nerdgraph), \
                mock.patch.object(controller, "entity_guid", lambda: "GUID"):
            controller.fire_marker("v1", "rollback: v2 -> v1", "newrelic-workflow-automation")
            self.assertEqual(sent["user"], "newrelic-workflow-automation")
            controller.fire_marker("v2", "deploy: v1 -> v2", "")
            self.assertEqual(sent["user"], "controller")

    def test_rollback_is_idempotent(self):
        self.client.post("/rollback", headers=AUTH)
        body = self.client.post("/rollback", headers=AUTH).get_json()
        self.assertTrue(body["noop"])
        self.assertTrue(body["verified"])
        self.assertEqual(self.cluster.ups, ["v1"])  # only one recreate

    def test_deploy_only_allows_known_versions(self):
        resp = self.client.post("/deploy", headers=AUTH, json={"version": "latest; rm -rf /"})
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(self.cluster.ups, [])

    def test_deploy_v2_from_v1(self):
        self.cluster.version = "v1"
        body = self.client.post("/deploy", headers=AUTH, json={"version": "v2"}).get_json()
        self.assertEqual(body["version_after"], "v2")
        self.assertTrue(body["verified"])

    def test_unhealthy_release_is_reported_not_verified(self):
        def broken_up(v):
            self.cluster.ups.append(v)  # container never reports the new version
        with mock.patch.object(controller, "compose_up", broken_up), \
                mock.patch.object(controller, "wait_for", lambda *a, **k: False):
            body = self.client.post("/rollback", headers=AUTH).get_json()
        self.assertEqual(body["status"], "failed")
        self.assertFalse(body["verified"])

    def test_compose_failure_is_reported(self):
        def boom(v):
            raise RuntimeError("daemon unreachable")
        with mock.patch.object(controller, "compose_up", boom):
            body = self.client.post("/rollback", headers=AUTH).get_json()
        self.assertEqual(body["status"], "error")
        self.assertFalse(body["verified"])

    def test_reset_returns_to_v1_and_flushes(self):
        body = self.client.post("/reset", headers=AUTH).get_json()
        self.assertEqual(body["version_after"], "v1")
        self.assertTrue(body["cache_flushed"])

    def test_status_is_public_and_lists_history(self):
        self.client.post("/rollback", headers=AUTH)
        body = self.client.get("/status").get_json()
        self.assertEqual(body["version"], "v1")
        self.assertEqual(body["history"][-1]["action"], "rollback")
        self.assertEqual(self.client.get("/").status_code, 200)

    def test_compose_command_has_no_shell_and_fixed_service(self):
        with mock.patch("subprocess.run") as run:
            REAL_COMPOSE_UP("v1")
        args, kwargs = run.call_args
        self.assertIsInstance(args[0], list)
        self.assertNotIn("shell", kwargs)
        self.assertEqual(args[0][-1], "shop-api")
        self.assertEqual(kwargs["env"]["APP_TAG"], "v1")

    def test_compose_env_does_not_leak_the_controller_app_name(self):
        with mock.patch.dict(os.environ, {"NEW_RELIC_APP_NAME": "wfa-controller"}), \
                mock.patch("subprocess.run") as run:
            REAL_COMPOSE_UP("v2")
        env = run.call_args.kwargs["env"]
        # Check the key only: a failing assertNotIn would print the whole environment, tokens included.
        self.assertFalse("NEW_RELIC_APP_NAME" in env, "NEW_RELIC_APP_NAME leaked into compose env")
        self.assertEqual(env["APP_TAG"], "v2")

    def test_history_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "history.json")
            with mock.patch.object(controller, "HISTORY_FILE", path):
                self.client.post("/rollback", headers=AUTH, json={"triggered_by": "test"})
                self.assertTrue(os.path.exists(path))
                controller._history.clear()  # what a restart does
                reloaded = controller.load_history()
        self.assertEqual(reloaded[-1]["action"], "rollback")
        self.assertEqual(reloaded[-1]["triggered_by"], "test")

    def test_unreadable_history_starts_empty(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not json")
        try:
            with mock.patch.object(controller, "HISTORY_FILE", f.name):
                self.assertEqual(controller.load_history(), [])
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
