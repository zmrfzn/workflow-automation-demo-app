"""Guards the APM wiring: each Python service reports as its own application."""
import os
import unittest

import yaml

COMPOSE = os.path.join(os.path.dirname(__file__), "..", "docker-compose.yml")

EXPECTED = {
    "shop-api": "workflow-automation-app",
    "controller": "workflow-automation-controller",
    "loadgen": "workflow-automation-loadgen",
}


def env_of(service):
    items = service.get("environment", [])
    return dict(i.split("=", 1) for i in items) if isinstance(items, list) else dict(items)


class ComposeWiring(unittest.TestCase):
    def setUp(self):
        with open(COMPOSE) as f:
            self.services = yaml.safe_load(f)["services"]

    def test_each_service_has_its_own_app_name(self):
        for name, app_name in EXPECTED.items():
            value = env_of(self.services[name])["NEW_RELIC_APP_NAME"]
            # shop-api reads its name from .env with a default; the sidecars are fixed
            self.assertIn(app_name, value, name)

    def test_app_names_are_distinct(self):
        names = [env_of(self.services[n])["NEW_RELIC_APP_NAME"] for n in EXPECTED]
        self.assertEqual(len(names), len(set(names)))

    def test_every_python_service_gets_the_license_key(self):
        for name in EXPECTED:
            self.assertIn("NEW_RELIC_LICENSE_KEY", env_of(self.services[name]), name)

    def test_controller_targets_the_app_not_itself(self):
        env = env_of(self.services["controller"])
        self.assertIn("workflow-automation-app", env["TARGET_APP_NAME"])
        self.assertNotEqual(env["TARGET_APP_NAME"], env["NEW_RELIC_APP_NAME"])

    def test_redis_is_published_on_loopback_only(self):
        ports = self.services["redis"].get("ports", [])
        self.assertTrue(ports and all(str(p).startswith("127.0.0.1:") for p in ports), ports)


if __name__ == "__main__":
    unittest.main()
