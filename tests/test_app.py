import importlib
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))


class FakeCache:
    """Minimal stand-in for redis.Redis."""
    def __init__(self):
        self.store = {}

    def get(self, key):
        return self.store.get(key)

    def set(self, key, value, ex=None):
        self.store[key] = value

    def ping(self):
        return True


def load(release):
    os.environ["APP_RELEASE"] = release
    for name in [n for n in sys.modules if n == "app" or n.startswith("releases")]:
        del sys.modules[name]
    module = importlib.import_module("app")
    module.cache = FakeCache()
    return module


class V1(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch("time.sleep")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.mod = load("v1")
        self.client = self.mod.app.test_client()

    def test_reports_version(self):
        self.assertEqual(self.client.get("/api/status").get_json()["version"], "v1")

    def test_every_endpoint_is_healthy(self):
        for path in ("orders", "inventory", "users", "checkout", "data", "products"):
            for _ in range(30):
                self.assertEqual(self.client.get(f"/api/{path}").status_code, 200, path)

    def test_products_hits_cache_on_second_call(self):
        first = self.client.get("/api/products").get_json()
        second = self.client.get("/api/products").get_json()
        self.assertEqual((first["source"], second["source"]), ("database", "cache"))

    def test_checkout_math(self):
        body = self.client.get("/api/checkout").get_json()
        self.assertEqual(body["total"], round(59.98 + 4.80 - 6.00, 2))


class V2(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch("time.sleep")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.mod = load("v2")
        self.client = self.mod.app.test_client()

    def test_reports_version(self):
        self.assertEqual(self.client.get("/api/status").get_json()["version"], "v2")

    def test_each_bug_surfaces_as_500_with_its_own_error(self):
        expected = {"inventory": "KeyError", "users": "AttributeError",
                    "checkout": "NameError", "data": "ValueError", "orders": "Timeout"}
        for path, name in expected.items():
            with mock.patch("random.random", return_value=0.0):
                resp = self.client.get(f"/api/{path}")
            self.assertEqual(resp.status_code, 500, path)
            self.assertEqual(resp.get_json()["error"], name, path)

    def test_products_never_uses_cache(self):
        for _ in range(3):
            self.assertEqual(self.client.get("/api/products").get_json()["source"], "database")
        self.assertEqual(self.mod.cache.store, {})


if __name__ == "__main__":
    unittest.main()
