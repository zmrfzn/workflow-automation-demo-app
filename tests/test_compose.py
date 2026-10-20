"""Guards the APM wiring: each Python service reports as its own application."""
import os
import unittest

import yaml

COMPOSE = os.path.join(os.path.dirname(__file__), "..", "docker-compose.yml")

EXPECTED = {
    "shop-api": "wfa-shop-api",
    "controller": "wfa-controller",
    "loadgen": "wfa-loadgen",
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
            self.assertEqual(env_of(self.services[name])["NEW_RELIC_APP_NAME"], app_name, name)

    def test_app_names_are_literals(self):
        # Interpolation let the controller's own name leak into shop-api (shell beats .env)
        values = [env_of(self.services[n])["NEW_RELIC_APP_NAME"] for n in EXPECTED]
        values.append(env_of(self.services["controller"])["TARGET_APP_NAME"])
        for value in values:
            self.assertNotIn("${", value)

    def test_app_names_are_distinct(self):
        names = [env_of(self.services[n])["NEW_RELIC_APP_NAME"] for n in EXPECTED]
        self.assertEqual(len(names), len(set(names)))

    def test_every_python_service_gets_the_license_key(self):
        for name in EXPECTED:
            self.assertIn("NEW_RELIC_LICENSE_KEY", env_of(self.services[name]), name)

    def test_controller_targets_the_app_not_itself(self):
        env = env_of(self.services["controller"])
        self.assertEqual(env["TARGET_APP_NAME"], EXPECTED["shop-api"])
        self.assertNotEqual(env["TARGET_APP_NAME"], env["NEW_RELIC_APP_NAME"])

    def test_redis_is_published_on_loopback_only(self):
        ports = self.services["redis"].get("ports", [])
        self.assertTrue(ports and all(str(p).startswith("127.0.0.1:") for p in ports), ports)

    def test_tls_proxies_to_the_controller_and_is_opt_in(self):
        tls = self.services["tls"]
        self.assertEqual(tls["profiles"], ["tls"])  # no certificate locally, so never on by default
        self.assertIn("5443:5443", tls["ports"])
        conf = os.path.join(os.path.dirname(COMPOSE), "tls", "nginx.conf")
        with open(conf) as f:
            self.assertIn("proxy_pass http://controller:5001;", f.read())


if __name__ == "__main__":
    unittest.main()
