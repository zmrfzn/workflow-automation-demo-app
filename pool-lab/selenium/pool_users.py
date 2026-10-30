#!/usr/bin/env python3
"""
Pool-lab pool-user tooling (accept invites, validate and reset shared passwords).

Adapted from automation/selenium/gameday.py for the pool-lab kit. Differences:
  * pool user addresses come from POOL_EMAIL_PREFIX + NNN + @POOL_USER_DOMAIN (no hardcoded
    "mars+"), the same scheme provision.sh uses, and POOL_USER_DOMAIN has no default;
  * the MARS-only workload / participants.csv code is removed;
  * you pick exactly one mode explicitly.

Usage (normally via ./provision.sh users <accept-invites|validate-passwords|reset-passwords>):
    cd pool-lab/selenium
    python -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

    python pool_users.py --accept-invites      # set the shared password via invites.json (Apps Script output)
    python pool_users.py --validate-passwords  # log in as every pool user (read-only)
    python pool_users.py --reset-pool-passwords  # change every pool user's password

Reads settings from the environment, loading pool-lab/.env (then selenium/.env) if present.
"""

import argparse
import json
import logging
import os
import sys
import time

from dotenv import load_dotenv

logging.getLogger("dotenv.main").setLevel(logging.ERROR)

_here = os.path.dirname(os.path.abspath(__file__))
for _env_path in [
    os.path.join(_here, "..", ".env"),  # pool-lab/.env (shared with provision.sh)
    os.path.join(_here, ".env"),
]:
    if os.path.isfile(_env_path):
        load_dotenv(_env_path)
        break
from selenium import webdriver  # noqa: E402
from selenium.webdriver.chrome.options import Options  # noqa: E402
from selenium.webdriver.chrome.service import Service  # noqa: E402
from selenium.webdriver.common.by import By  # noqa: E402
from selenium.webdriver.support.ui import WebDriverWait  # noqa: E402
from selenium.webdriver.support import expected_conditions as EC  # noqa: E402
from selenium.common.exceptions import TimeoutException, NoSuchElementException  # noqa: E402
from webdriver_manager.chrome import ChromeDriverManager  # noqa: E402

# Invites parsed by pool-lab/appsscript/parse-invitations.gs: [{to, accept_link, password}]
USERS_FILE = os.environ.get("POOL_INVITES_FILE") or os.path.join(_here, "..", "invites.json")

# The region decides which New Relic login/UI hosts are used. EU hosts are UNVERIFIED.
_EU = os.environ.get("NR_REGION", "US").strip().upper() == "EU"
LOGIN_HOST = "login.eu.newrelic.com" if _EU else "login.newrelic.com"
ONE_HOST = "one.eu.newrelic.com" if _EU else "one.newrelic.com"
LOGIN_URL = f"https://{LOGIN_HOST}/login"
ONE_NR_URL = f"https://{ONE_HOST}"
CHANGE_PASSWORD_URL = f"https://{LOGIN_HOST}/passwords/change"
WAIT_TIMEOUT = 15  # seconds


def load_users(path):
    with open(path) as f:
        return json.load(f)


def accept_invite(driver, invite):
    """Set the password via the accept link. Returns False if already set (skipped)."""
    email = invite["to"]
    url = invite["accept_link"]
    password = invite["password"]

    print(f"  Navigating to accept link for {email} ...")
    driver.get(url)

    wait = WebDriverWait(driver, WAIT_TIMEOUT)

    # Check immediately for the "invite is invalid" message (already accepted)
    try:
        WebDriverWait(driver, 3).until(
            EC.text_to_be_present_in_element(
                (By.CSS_SELECTOR, "body"), "invite is invalid"
            )
        )
        print("  Invite already accepted — skipping to login")
        return False
    except TimeoutException:
        pass

    # Wait for the password field — if it never appears the invite was already accepted
    try:
        password_field = wait.until(
            EC.visibility_of_element_located(
                (By.CSS_SELECTOR, "input[type='password']")
            )
        )
    except TimeoutException:
        print(
            "  Password field not found — invite already accepted, skipping to login"
        )
        return False

    password_field.clear()
    password_field.send_keys(password)

    # Fill confirmation field if present
    try:
        confirm_fields = driver.find_elements(By.CSS_SELECTOR, "input[type='password']")
        if len(confirm_fields) >= 2:
            confirm_fields[1].clear()
            confirm_fields[1].send_keys(password)
    except NoSuchElementException:
        pass

    # Click the submit / save button
    try:
        submit = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR, "button[type='submit'], input[type='submit']")
            )
        )
        submit.click()
    except TimeoutException:
        raise RuntimeError("Submit button did not become clickable within timeout")

    # Wait for a URL change or success indicator (redirect away from the verification page)
    try:
        wait.until(EC.url_changes(url))
    except TimeoutException:
        # Some flows stay on the same URL but show a success message — not a hard failure
        print(
            f"  Warning: URL did not change after submit for {email} (may still have succeeded)"
        )

    return True


def login(driver, email, password):
    print(f"  Logging in as {email} ...")
    driver.get(LOGIN_URL)

    wait = WebDriverWait(driver, WAIT_TIMEOUT)

    # If already logged in, the login page redirects away within a couple of seconds
    try:
        WebDriverWait(driver, 4).until(
            lambda d: LOGIN_HOST not in d.current_url
        )
        print("  Already logged in — skipping login form")
        driver.get(ONE_NR_URL)
        WebDriverWait(driver, WAIT_TIMEOUT).until(
            lambda d: d.execute_script("return document.readyState") == "complete"
        )
        print(f"  Session active (landed on {driver.current_url})")
        return {c["name"]: c["value"] for c in driver.get_cookies()}
    except TimeoutException:
        pass  # Still on the login page — proceed with the form

    # Step 1: fill email and click Next
    try:
        email_field = wait.until(
            EC.visibility_of_element_located(
                (
                    By.CSS_SELECTOR,
                    "input[type='email'], input[name='login[email]'], input[id='login_email']",
                )
            )
        )
    except TimeoutException:
        raise RuntimeError("Email field did not appear on login page")

    email_field.clear()
    email_field.send_keys(email)

    try:
        next_btn = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR, "button[type='submit'], input[type='submit']")
            )
        )
        next_btn.click()
    except TimeoutException:
        raise RuntimeError("Next button did not become clickable after entering email")

    # Step 2: password field appears after Next
    try:
        password_field = wait.until(
            EC.visibility_of_element_located(
                (By.CSS_SELECTOR, "input[type='password']")
            )
        )
    except TimeoutException:
        raise RuntimeError("Password field did not appear after clicking Next")

    password_field.clear()
    password_field.send_keys(password)

    try:
        submit = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR, "button[type='submit'], input[type='submit']")
            )
        )
        submit.click()
    except TimeoutException:
        raise RuntimeError("Login submit button did not become clickable")

    # Wait for redirect away from the login page
    try:
        wait.until(EC.url_changes(LOGIN_URL))
    except TimeoutException:
        raise RuntimeError(
            "Login did not redirect — credentials may be wrong or MFA required"
        )

    # Land on one.newrelic.com so we collect all relevant session cookies
    driver.get(ONE_NR_URL)
    WebDriverWait(driver, WAIT_TIMEOUT).until(
        lambda d: d.execute_script("return document.readyState") == "complete"
    )
    print(f"  Logged in successfully (landed on {driver.current_url})")

    # Return cookies as a requests-compatible dict
    return {c["name"]: c["value"] for c in driver.get_cookies()}



def _pool_addresses():
    """Pool addresses ${POOL_EMAIL_PREFIX}NNN@${POOL_USER_DOMAIN}, NNN = 001..POOL_USER_COUNT.

    Matches provision.sh exactly (3-digit zero padding). POOL_USER_DOMAIN has NO default on
    purpose: guessing a domain could point this at addresses you do not own.
    """
    prefix = os.environ.get("POOL_EMAIL_PREFIX", "labpool+")
    domain = os.environ.get("POOL_USER_DOMAIN", "").strip()
    count = int(os.environ.get("POOL_USER_COUNT", "20"))
    if not domain:
        raise SystemExit("Error: POOL_USER_DOMAIN is not set (the mail domain of the pool users)")
    if prefix.lower().startswith("mars+"):
        raise SystemExit(
            "Error: POOL_EMAIL_PREFIX 'mars+' is the MARS pool. Use the pool-lab prefix, "
            "or use automation/selenium/gameday.py for MARS."
        )
    return [f"{prefix}{i:03d}@{domain}" for i in range(1, count + 1)]


def build_pool_users():
    """Build the pool user list for --reset-pool-passwords.

    Reads POOL_EMAIL_PREFIX, POOL_USER_DOMAIN, POOL_USER_COUNT,
    POOL_CURRENT_PASSWORD (current shared password) and POOL_NEW_PASSWORD (new one).
    """
    current_password = os.environ.get("POOL_CURRENT_PASSWORD", "")
    new_password = os.environ.get("POOL_NEW_PASSWORD", "")

    if not current_password:
        raise SystemExit("Error: POOL_CURRENT_PASSWORD env var is required for --reset-pool-passwords")
    if not new_password:
        raise SystemExit("Error: POOL_NEW_PASSWORD env var is required for --reset-pool-passwords")

    return [
        {"email": email, "current_password": current_password, "new_password": new_password}
        for email in _pool_addresses()
    ]


def build_pool_validation_users():
    """Build the pool user list for --validate-passwords (read-only).

    Reads POOL_EMAIL_PREFIX, POOL_USER_DOMAIN, POOL_USER_COUNT and POOL_PASSWORD, falling back
    to POOL_NEW_PASSWORD (the password left in place after a --reset-pool-passwords run).
    """
    password = os.environ.get("POOL_PASSWORD", "") or os.environ.get("POOL_NEW_PASSWORD", "")

    if not password:
        raise SystemExit(
            "Error: set POOL_PASSWORD (or POOL_NEW_PASSWORD) to the expected pool "
            "password for --validate-passwords"
        )

    return [{"email": email, "password": password} for email in _pool_addresses()]


def validate_logins(driver, users):
    """Verify each user's password by logging in. Read-only — makes no changes.

    Each user dict needs {email, password}. Returns a list of (email, ok, err)
    tuples. Cookies are cleared between users so every login is a fresh password
    test (and never short-circuits via the 'already logged in' fast path).
    """
    results = []
    for user in users:
        email = user["email"]
        print(f"[{email}]")
        try:
            login(driver, email, user["password"])
            driver.delete_all_cookies()
            print("  -> OK (password valid)\n")
            results.append((email, True, None))
        except Exception as exc:
            driver.delete_all_cookies()
            print(f"  -> FAIL: {exc}\n")
            results.append((email, False, str(exc)))
    return results


def change_password(driver, current_password, new_password):
    """Navigate to the NR password change page and set the new password."""

    wait = WebDriverWait(driver, WAIT_TIMEOUT)

    print("  Navigating to password change page ...")
    driver.get(CHANGE_PASSWORD_URL)

    # Wait for at least two password inputs to appear (Current + New)
    try:
        wait.until(lambda d: len(d.find_elements(By.CSS_SELECTOR, "input[type='password']")) >= 2)
    except TimeoutException:
        raise RuntimeError("Password change form did not load (expected 2 password fields)")

    fields = driver.find_elements(By.CSS_SELECTOR, "input[type='password']")
    # Form has exactly: [0] Current, [1] New
    fields[0].clear()
    fields[0].send_keys(current_password)
    fields[1].clear()
    fields[1].send_keys(new_password)

    # Submit ("Reset password" button)
    try:
        submit = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR, "button[type='submit'], input[type='submit']")
            )
        )
        submit.click()
    except TimeoutException:
        raise RuntimeError("Submit button did not become clickable on password change page")

    # Wait for a success indicator or URL change
    try:
        wait.until(EC.url_changes(CHANGE_PASSWORD_URL))
        print("  Password changed successfully")
    except TimeoutException:
        # Some flows show a success banner without navigating away
        try:
            _lc = "translate(text(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')"
            _xpath = f"//*[contains({_lc},'password') and contains({_lc},'success')]"
            WebDriverWait(driver, 5).until(
                EC.presence_of_element_located((By.XPATH, _xpath))
            )
            print("  Password changed successfully (success banner detected)")
        except TimeoutException:
            print("  Warning: could not confirm password change — check manually")


def main():
    parser = argparse.ArgumentParser(description="Pool-lab pool-user tooling")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--accept-invites",
        action="store_true",
        help="Open each accept link in the invites file and set the shared password.",
    )
    mode.add_argument(
        "--validate-passwords",
        action="store_true",
        help=(
            "Read-only: log in as every pool user to verify its password (no changes). "
            "Reads POOL_EMAIL_PREFIX, POOL_USER_DOMAIN, POOL_USER_COUNT and POOL_PASSWORD "
            "(falls back to POOL_NEW_PASSWORD)."
        ),
    )
    mode.add_argument(
        "--reset-pool-passwords",
        action="store_true",
        help=(
            "Log in as every pool user and change the password. "
            "Reads POOL_EMAIL_PREFIX, POOL_USER_DOMAIN, POOL_USER_COUNT, "
            "POOL_CURRENT_PASSWORD and POOL_NEW_PASSWORD."
        ),
    )
    parser.add_argument(
        "--headless", action="store_true", help="Run Chrome without a visible window."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the users that would be processed and exit without opening a browser.",
    )
    args = parser.parse_args()

    # Build and validate the work list BEFORE starting Chrome, so config errors fail fast
    # and --dry-run never launches a browser.
    if args.validate_passwords:
        work = build_pool_validation_users()
        label = "Validating passwords for {n} pool user(s) (read-only)"
    elif args.reset_pool_passwords:
        work = build_pool_users()
        label = "Resetting passwords for {n} pool user(s)"
    else:
        work = load_users(USERS_FILE)
        label = "Accepting {n} invite(s) from " + str(USERS_FILE)
    print(label.format(n=len(work)) + "\n")

    if args.dry_run:
        for item in work:
            print("  " + item.get("email", item.get("to", "?")))
        print("\nDry run: no browser started, nothing changed.")
        return

    options = Options()
    if args.headless:
        options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")

    driver = webdriver.Chrome(
        service=Service(ChromeDriverManager().install()),
        options=options,
    )

    results = []
    try:
        if args.validate_passwords:
            results = validate_logins(driver, work)
        elif args.reset_pool_passwords:
            for user in work:
                email = user["email"]
                print(f"[{email}]")
                try:
                    login(driver, email, user["current_password"])
                    change_password(driver, user["current_password"], user["new_password"])
                    driver.delete_all_cookies()  # next user gets a fresh login
                    print("  -> OK\n")
                    results.append((email, True, None))
                except Exception as exc:
                    driver.delete_all_cookies()
                    print(f"  -> FAIL: {exc}\n")
                    results.append((email, False, str(exc)))
        else:
            for invite in work:
                email = invite["to"]
                print(f"[{email}]")
                try:
                    accepted = accept_invite(driver, invite)
                    if not accepted:
                        print("  (skipped password setup)")
                    # Log in once to prove the password now works, then clear the session.
                    login(driver, email, invite["password"])
                    driver.delete_all_cookies()
                    print("  -> OK\n")
                    results.append((email, True, None))
                except Exception as exc:
                    driver.delete_all_cookies()
                    print(f"  -> FAIL: {exc}\n")
                    results.append((email, False, str(exc)))
    finally:
        driver.quit()

    print("=" * 60)
    print("Results:")
    for email, ok, err in results:
        status = "OK  " if ok else "FAIL"
        line = f"  [{status}] {email}"
        if err:
            line += f"  — {err}"
        print(line)

    failed = sum(1 for _, ok, _ in results if not ok)
    print(f"\n{len(results) - failed} ok, {failed} failed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
