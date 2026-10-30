# pool-lab Selenium tooling

`pool_users.py` drives the New Relic web UI with Chrome to handle the pool users' invites and shared password.
It is the pool-lab adaptation of `automation/selenium/gameday.py`, which is left untouched and still serves MARS.
You normally run it through `../provision.sh users ...`, but it also runs directly.

## Setup

Chrome must be installed on the machine that runs the tool.
The matching chromedriver is downloaded automatically (by `webdriver-manager`) on the first run, so that run needs internet access.

```bash
cd pool-lab/selenium
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`provision.sh` looks for the interpreter at `pool-lab/selenium/.venv/bin/python`.
Set `POOL_LAB_PYTHON` to use a different one.
`.venv/` is gitignored.

Settings come from the environment.
`pool_users.py` also loads `pool-lab/.env` (falling back to `selenium/.env`) when it exists, without overriding variables that are already set.
`provision.sh` exports its own settings to the script, so after `set -a; source .env; set +a` both entry points see the same values.

## Modes

Pick exactly one mode.
All modes accept `--headless` (no visible Chrome window) and `--dry-run` (print the users that would be processed and exit, with no browser started and nothing changed).
Run `--dry-run` first: it fails fast on missing settings and shows the exact addresses.

| Mode | provision.sh | Direct flag | What it changes |
| --- | --- | --- | --- |
| Accept invites | `users accept-invites` | `--accept-invites` | Sets the shared password on each pool user by opening its accept link, then logs in once to prove it works |
| Validate passwords | `users validate-passwords` | `--validate-passwords` | **Nothing.** Logs in as every pool user and reports pass or fail |
| Reset passwords | `users reset-passwords` | `--reset-pool-passwords` | Logs in with the current shared password and changes it to the new one, for every pool user |

### Accept invites

Reads `pool-lab/invites.json` (or `POOL_INVITES_FILE`), which is produced by the optional Apps Script in `../appsscript/`.
For each entry it opens `accept_link`, sets the password, and then does a login to verify it.
An invite that was already accepted is skipped and the tool goes straight to the login check.

```bash
cd pool-lab
./provision.sh users accept-invites --dry-run
./provision.sh users accept-invites --headless

# or directly
cd selenium && .venv/bin/python pool_users.py --accept-invites --headless
```

This mode takes its addresses from `invites.json`, so it does not need `POOL_USER_DOMAIN`.

### Validate passwords

Read-only.
It logs in as every pool user (`POOL_EMAIL_PREFIX` + `001..POOL_USER_COUNT` + `@POOL_USER_DOMAIN`) with the shared password, clears the browser session between users, and prints one `OK` or `FAIL` line per user.
It exits non-zero if any user failed.
It never creates, changes, or deletes anything.

```bash
cd pool-lab
POOL_PASSWORD='the-shared-password' ./provision.sh users validate-passwords --dry-run
POOL_PASSWORD='the-shared-password' ./provision.sh users validate-passwords --headless

# or directly
cd selenium && POOL_PASSWORD='the-shared-password' .venv/bin/python pool_users.py --validate-passwords --headless
```

The password is `POOL_PASSWORD`, falling back to `POOL_NEW_PASSWORD` (the password left in place after a reset).

### Reset passwords

Changes the password of every pool user, so use it deliberately.
It logs in with `POOL_CURRENT_PASSWORD` and sets `POOL_NEW_PASSWORD` on the New Relic password change page.
Update the lab's shared-password Instruqt secret afterwards, and run `validate-passwords` to confirm.

```bash
cd pool-lab
POOL_CURRENT_PASSWORD='old' POOL_NEW_PASSWORD='new' ./provision.sh users reset-passwords --dry-run
POOL_CURRENT_PASSWORD='old' POOL_NEW_PASSWORD='new' ./provision.sh users reset-passwords --headless

# or directly
cd selenium && POOL_CURRENT_PASSWORD='old' POOL_NEW_PASSWORD='new' .venv/bin/python pool_users.py --reset-pool-passwords --headless
```

## Environment variables

| Variable | Default | Used by | Description |
| --- | --- | --- | --- |
| `POOL_EMAIL_PREFIX` | `labpool+` | validate, reset | Pool address prefix; the tool refuses `mars+` |
| `POOL_USER_DOMAIN` | none (required) | validate, reset | Mail domain of the pool users; there is deliberately no default |
| `POOL_USER_COUNT` | `20` | validate, reset | Users `001` to `POOL_USER_COUNT` are processed |
| `POOL_PASSWORD` | none | validate | Shared password to check |
| `POOL_CURRENT_PASSWORD` | none | reset | Current shared password |
| `POOL_NEW_PASSWORD` | none | reset, validate fallback | New shared password |
| `POOL_INVITES_FILE` | `pool-lab/invites.json` | accept | Path to the invites JSON |
| `POOL_LAB_PYTHON` | `selenium/.venv/bin/python` | `provision.sh` only | Python interpreter to run |
| `NR_REGION` | `US` | all | `EU` switches to the EU login and UI hosts (unverified, see below) |

## invites.json format

A JSON array with one object per pool user, produced by `../appsscript/parse-invitations.gs`:

```json
[
  {
    "to": "labpool+001@example.com",
    "accept_link": "https://login.newrelic.com/invitations/...",
    "password": "<shared password>"
  }
]
```

The file holds the shared password and one-time accept links, so it is gitignored and must not be committed.

## Differences from automation/selenium/gameday.py

- Addresses are built as `POOL_EMAIL_PREFIX` + `NNN` + `@POOL_USER_DOMAIN`, the same scheme `provision.sh` uses.
  There is no hardcoded `mars+` and no default domain, and the tool refuses a `mars+` prefix.
- The MARS-only code is removed: workload creation and the `participants.csv` handling.
- You choose the mode with an explicit flag, and exactly one is required.
- `--headless` and `--dry-run` are new, and `--dry-run` never starts a browser.
- `--validate-passwords` is new and read-only.
- `NR_REGION=EU` switches to `login.eu.newrelic.com` and `one.eu.newrelic.com`.
  These EU hosts are **unverified** and have not been tested.
- It loads `pool-lab/.env`.

## Troubleshooting

- **Chrome or chromedriver errors.**
  Confirm Chrome is installed and recent, and that the first run could reach the internet to download the driver.
  If the driver and browser versions drift apart, upgrade `selenium` and `webdriver-manager` in the venv, or delete the cached driver under `~/.wdm`.
- **Login FAIL for some users.**
  Usually the invite was not accepted (the user is still pending), the password differs for that user, or the account needs MFA.
  Check the `FAIL` reason printed for each user.
- **Selectors stop matching.**
  The tool relies on the current New Relic login pages.
  If New Relic changes them, fix the selectors in `pool_users.py`.
