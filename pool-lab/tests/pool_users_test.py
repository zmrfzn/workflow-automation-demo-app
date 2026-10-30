#!/usr/bin/env python3
"""Offline tests for selenium/pool_users.py. No browser, no network, no selenium install needed.

selenium / webdriver_manager / dotenv are replaced with MagicMock modules before import, and the
webdriver is asserted to be NEVER constructed in the modes under test.
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "..", "selenium", "pool_users.py")

_FAKE_MODULES = [
    "dotenv",
    "selenium",
    "selenium.webdriver",
    "selenium.webdriver.chrome",
    "selenium.webdriver.chrome.options",
    "selenium.webdriver.chrome.service",
    "selenium.webdriver.common",
    "selenium.webdriver.common.by",
    "selenium.webdriver.support",
    "selenium.webdriver.support.ui",
    "selenium.webdriver.support.expected_conditions",
    "selenium.common",
    "selenium.common.exceptions",
    "webdriver_manager",
    "webdriver_manager.chrome",
]

POOL_ENV_KEYS = [
    "POOL_EMAIL_PREFIX", "POOL_USER_DOMAIN", "POOL_USER_COUNT", "POOL_PASSWORD",
    "POOL_NEW_PASSWORD", "POOL_CURRENT_PASSWORD", "POOL_INVITES_FILE", "NR_REGION",
]


def load_module(env):
    """Import a fresh copy of pool_users.py with fake third-party modules and the given env."""
    saved = {k: os.environ.pop(k, None) for k in POOL_ENV_KEYS}
    os.environ.update(env)
    fakes = {name: mock.MagicMock() for name in _FAKE_MODULES}
    # `except TimeoutException` needs real exception classes
    fakes["selenium.common.exceptions"].TimeoutException = type("TimeoutException", (Exception,), {})
    fakes["selenium.common.exceptions"].NoSuchElementException = type("NoSuchElementException", (Exception,), {})
    with mock.patch.dict(sys.modules, fakes):
        spec = importlib.util.spec_from_file_location("pool_users_under_test", TARGET)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    for k, v in saved.items():  # restore ambient env after import-time reads
        if v is not None:
            os.environ[k] = v
    mod._fakes = fakes
    return mod


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in POOL_ENV_KEYS}
        for k in POOL_ENV_KEYS:
            os.environ.pop(k, None)
        self.mod = load_module({})

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_addresses_use_prefix_domain_and_three_digit_padding(self):
        os.environ.update(POOL_EMAIL_PREFIX="labpool+", POOL_USER_DOMAIN="example.com", POOL_USER_COUNT="3")
        self.assertEqual(
            self.mod._pool_addresses(),
            ["labpool+001@example.com", "labpool+002@example.com", "labpool+003@example.com"],
        )

    def test_default_prefix_and_count_match_provision_sh(self):
        os.environ["POOL_USER_DOMAIN"] = "example.com"
        addrs = self.mod._pool_addresses()
        self.assertEqual(len(addrs), 20)
        self.assertEqual(addrs[0], "labpool+001@example.com")
        self.assertEqual(addrs[-1], "labpool+020@example.com")

    def test_domain_is_required_no_default(self):
        with self.assertRaises(SystemExit) as cm:
            self.mod._pool_addresses()
        self.assertIn("POOL_USER_DOMAIN", str(cm.exception))

    def test_refuses_the_mars_prefix(self):
        os.environ.update(POOL_EMAIL_PREFIX="mars+", POOL_USER_DOMAIN="example.com")
        with self.assertRaises(SystemExit) as cm:
            self.mod._pool_addresses()
        self.assertIn("MARS", str(cm.exception))
        os.environ["POOL_EMAIL_PREFIX"] = "MARS+"  # case-insensitive
        with self.assertRaises(SystemExit):
            self.mod._pool_addresses()

    def test_validation_users_use_pool_password_then_fall_back_to_new_password(self):
        os.environ.update(POOL_USER_DOMAIN="example.com", POOL_USER_COUNT="2")
        with self.assertRaises(SystemExit):
            self.mod.build_pool_validation_users()  # no password at all
        os.environ["POOL_NEW_PASSWORD"] = "fallback"
        self.assertEqual([u["password"] for u in self.mod.build_pool_validation_users()], ["fallback"] * 2)
        os.environ["POOL_PASSWORD"] = "primary"
        self.assertEqual([u["password"] for u in self.mod.build_pool_validation_users()], ["primary"] * 2)

    def test_reset_users_need_both_passwords(self):
        os.environ.update(POOL_USER_DOMAIN="example.com", POOL_USER_COUNT="1")
        with self.assertRaises(SystemExit):
            self.mod.build_pool_users()
        os.environ["POOL_CURRENT_PASSWORD"] = "old"
        with self.assertRaises(SystemExit):
            self.mod.build_pool_users()
        os.environ["POOL_NEW_PASSWORD"] = "new"
        self.assertEqual(
            self.mod.build_pool_users(),
            [{"email": "labpool+001@example.com", "current_password": "old", "new_password": "new"}],
        )

    def test_no_mars_hardcoding_left_in_source(self):
        with open(TARGET) as fh:
            src = fh.read()
        self.assertNotIn('f"mars+', src)
        self.assertNotIn('"example.com")', src)  # no default domain


class RegionTests(unittest.TestCase):
    def test_us_hosts_by_default(self):
        mod = load_module({})
        self.assertEqual(mod.LOGIN_URL, "https://login.newrelic.com/login")
        self.assertEqual(mod.LOGIN_HOST, "login.newrelic.com")

    def test_eu_hosts_when_region_is_eu(self):
        mod = load_module({"NR_REGION": "eu"})
        self.assertEqual(mod.LOGIN_URL, "https://login.eu.newrelic.com/login")
        self.assertEqual(mod.ONE_NR_URL, "https://one.eu.newrelic.com")


class MainTests(unittest.TestCase):
    def run_main(self, argv, env):
        for k in POOL_ENV_KEYS:
            os.environ.pop(k, None)
        mod = load_module(env)
        os.environ.update(env)  # builders read os.environ at call time
        out = io.StringIO()
        code = 0
        with mock.patch.object(sys, "argv", ["pool_users.py"] + argv), redirect_stdout(out):
            try:
                mod.main()
            except SystemExit as exc:
                code = exc.code if isinstance(exc.code, int) else 1
                if isinstance(exc.code, str):
                    out.write(exc.code)
        return mod, out.getvalue(), code

    def test_a_mode_is_required(self):
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            _, _, code = self.run_main([], {})
        self.assertEqual(code, 2)

    def test_validate_dry_run_lists_users_and_never_starts_chrome(self):
        mod, out, code = self.run_main(
            ["--validate-passwords", "--dry-run"],
            {"POOL_EMAIL_PREFIX": "labpool+", "POOL_USER_DOMAIN": "example.com",
             "POOL_USER_COUNT": "2", "POOL_PASSWORD": "pw"},
        )
        self.assertEqual(code, 0)
        self.assertIn("labpool+001@example.com", out)
        self.assertIn("labpool+002@example.com", out)
        self.assertIn("no browser started", out)
        mod._fakes["selenium"].webdriver.Chrome.assert_not_called()

    def test_validation_config_errors_fail_before_chrome_starts(self):
        mod, out, code = self.run_main(["--validate-passwords"], {"POOL_USER_DOMAIN": "example.com"})
        self.assertNotEqual(code, 0)
        self.assertIn("POOL_PASSWORD", out)
        mod._fakes["selenium"].webdriver.Chrome.assert_not_called()

    def test_accept_invites_dry_run_reads_invites_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump([{"to": "labpool+001@example.com", "accept_link": "https://x/y", "password": "pw"}], f)
            path = f.name
        try:
            mod, out, code = self.run_main(["--accept-invites", "--dry-run"], {"POOL_INVITES_FILE": path})
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        self.assertIn("labpool+001@example.com", out)
        mod._fakes["selenium"].webdriver.Chrome.assert_not_called()

    def test_reset_dry_run_requires_both_passwords(self):
        mod, out, code = self.run_main(
            ["--reset-pool-passwords", "--dry-run"],
            {"POOL_USER_DOMAIN": "example.com", "POOL_USER_COUNT": "1"},
        )
        self.assertNotEqual(code, 0)
        self.assertIn("POOL_CURRENT_PASSWORD", out)
        mod._fakes["selenium"].webdriver.Chrome.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
