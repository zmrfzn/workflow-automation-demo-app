# AGENTS.md — pool-lab

Project memory for coding agents.
Read this first if the project was moved to a new repo.
Last updated 2026-10-30 (grant fix, merged into demo-app/pool-lab).

First consumer: the Workflow Automation masterclass track (`devrel-workflow-automation-masterclass/`, VM `wfa-infra`), where this kit is Phase 6 (account provisioning and mapping) in that track's `STATUS.md`.
**Single home (since 2026-10-30):** `devrel-workflow-automation-masterclass/demo-app/pool-lab/`, inside the `demo-app` checkout (`zmrfzn/workflow-automation-demo-app`).
Committed on branch `pool-user-subaccount-module` (`8c6aa19`, no upstream, not pushed); the branch also carries the loadgen hardening cherry-picked from `main`.
It was developed in `newrelic/mars-instruqt/pool-lab/` (branch `pool-user-subaccount-module`) and moved here; that copy is retired (only a `MOVED.md` pointer remains).
The previous `demo-app/pool-lab` copy is backed up at `codespace/instruqt/pool-lab-backup-2026-10-30/`.
`pool-lab/.gitignore` now carries all its own ignore rules (`.env`, `dist/`, `invites.json`, `selenium/.venv/`, `__pycache__/`, `.hypergrep/`).
The demo-app repo is public: do not push `pool-lab` there unless that is intended (it holds no secrets, but it is instructor tooling).

## Goal

Reuse the idea behind the MARS track's per-team New Relic sub-accounts and pool-user mapping for a different, non-MARS New Relic org, inside Instruqt, on a stock image (no custom VM image).
Target size is about 15–20 learners per workshop.
Learners need to log in to New Relic and send telemetry, so each lab needs a sub-account id, an ingest license key and a login.

Origin: the MARS repo creates a sub-account per team at lab start with Terraform and waits up to about 10 minutes for the admin grant to propagate.
It then claims a pool user (`mars+NNN@…`), adds them to a `<account> - ReadOnly` group, and tears it all down afterwards.
That depends on a custom image and is hardwired to the MARS org and a `mars` mail group.

## Design decisions (made with the user)

1. Pool users are created ahead of time, with invite emails going to a mailbox or Google Group the user controls.
2. Sub-accounts, `<account> - ReadOnly` groups, grants and license keys are also created ahead of time, once, by an instructor CLI.
   The 10-minute propagation wait therefore happens before the workshop, not at lab start.
3. At lab start the VM only claims a free pool user and a free group and links them (one membership write plus an exclusivity check).
   Dynamic claim: free user = pool user with no groups, free group = lab group with no pool-user members.
4. The lab VM needs only `curl` and `jq`: no Terraform, no repo clone, no baked helpers.
5. No Apps Script or GCP automation for the first batch: the user accepts the ~15–20 invites by hand.
   Optional copies of the Apps Script and Selenium tooling exist for later.
6. Different org and domain from MARS.
   The invite address scheme is `${POOL_EMAIL_PREFIX}NNN@${POOL_USER_DOMAIN}`, configured to `labpool+NNN@example.com`, backed by a Google Group `labpool@example.com` owned by the user.
7. Phase 2 (not built): a fixed user-to-account manifest the lab only reads.
   `bootstrap.sh` keeps a single `resolve_pair` function as the seam for `LAB_MAPPING_MODE=manifest`.

## Constraints and working agreements

- The directory is self-contained and shares no code with MARS (`scenarios/`, `mars-program/`, `scripts/`, `automation/` are untouched in the source repo).
- Never run NerdGraph mutations without the user's permission.
  The user explicitly authorised one real single-account run on 2026-10-21 and nothing beyond it.
- Never print or read out API keys or license key values.
- Tests are offline (stubbed `gql`), need no API key and must keep passing.
- Instructor scripts are Bash 3.2 compatible (macOS): no associative arrays, no `${v^^}`, no `mapfile`, no empty-array expansion under `set -u`.
- Markdown follows one sentence per line.
- Use `hypergrep` for code searches and `fd` for finding files.

## Layout

| Path | Purpose |
| --- | --- |
| `provision.sh` | Instructor CLI (see commands below). Auto-sources `pool-lab/.env`. |
| `lib/common.sh` | Print helpers, NerdGraph `gql` (curl, or `newrelic` CLI fallback), paginated `fetch_users` / `fetch_lab_groups`, accounts and license-key lookup, `agent_var_set/get` with file fallback. |
| `lib/claim.sh` | `claim_pair`: pick a free user and group, add membership, re-poll both sides, roll back and retry with jitter on collision. |
| `lib/scrub.sh` | `scrub_account <id>`: delete everything a learner created in a lab account (see "Account scrub"). Used by `teardown.sh` and `provision.sh accounts scrub`. |
| `lab/bootstrap.sh`, `lab/teardown.sh` | Run in the Instruqt VM at lab start and end. Bootstrap claims the pair, resolves the account id and license key, and sets agent variables. Teardown scrubs the account, then removes the user from the group. |
| `build-lab-scripts.sh` | Builds self-contained `dist/setup-<vm>` and `dist/cleanup-<vm>` track scripts (lines marked `# pool-lab:inline` are dropped). |
| `instruqt/config.snippet.yml` | Secrets and env to merge into the track's `config.yml`. |
| `selenium/pool_users.py` | Browser tooling copied from MARS `gameday.py`: accept invites, validate shared password (read-only), reset passwords. |
| `appsscript/parse-invitations.gs` | Optional Gmail → `invites.json` parser for `--accept-invites`. |
| `tests/` | `claim-test.sh` (20), `provision-test.sh` (62), `bootstrap-test.sh` (38), `scrub-test.sh` (37), `pool-users-test.sh` (13 plus 14 Python unittests). |
| `README.md` | Human runbook: before the workshop, at lab start, after the workshop, troubleshooting. |

## Commands

```bash
cd pool-lab
./provision.sh users create | status | free [email] | delete
./provision.sh users accept-invites | validate-passwords | reset-passwords   # browser tooling, no API key
./provision.sh accounts create [N] | status | scrub <account|--all> | destroy
./provision.sh pair claim [email "account name"]    # local test of the lab-time mapping, no Instruqt
# flags: --dry-run (read-only), --yes, --headless
./tests/claim-test.sh && ./tests/provision-test.sh && ./tests/bootstrap-test.sh && ./tests/scrub-test.sh && ./tests/pool-users-test.sh
```

Local run of the lab scripts: set `LAB_NR_API_KEY_SECRET=NEW_RELIC_API_KEY`, run `lab/bootstrap.sh`, check `/tmp/pool-lab-vars/`, then `lab/teardown.sh`.

## Current configuration (user's `pool-lab/.env`, gitignored)

- `POOL_EMAIL_PREFIX=labpool+`, `POOL_USER_DOMAIN=example.com`, `POOL_USER_COUNT=2` (trial size).
- `LAB_ACCOUNT_PREFIX=INSTRUQT_LAB`, `LAB_ACCOUNT_COUNT=20`, `LAB_ACCOUNT_REGION=us01`.
- `LAB_ADMIN_GROUP_NAME=Admin`, `LAB_ADMIN_ROLE=all_product_admin`, `LAB_READONLY_ROLE=read_only`.
  `read_only` is too weak for the masterclass; it must become `all_product_admin` (see "Learner role and account visibility").
- `NR_REGION=US`, `NR_GRAPHQL_URL=https://api.newrelic.com/graphql`.
- `POOL_PASSWORD` (shared pool-user password) is not set yet.
- The same `POOL_EMAIL_PREFIX` and `LAB_ACCOUNT_PREFIX` must be set on the lab VM (`instruqt/config.snippet.yml`).

## Outcome so far

Built and passing offline: the whole kit above, with all four test suites green.

Verified against the real org (<org-id>, US, 2026-10-21):
- `users create` creates the pool users.
- `accounts status` and the org / auth-domain lookup work.
- `accountManagementCreateAccount` works with `managedAccount: {name, regionCode}`.
  The API's own hint said `region_code`, which is wrong. `regionCode` is correct.
- The admin grant works and the account is visible on the first poll.
- The license key permission lags the grant by about 2 minutes: `keySearch` first fails with "You do not have permission to view license keys".
  `provision.sh` retries on that error (`_license_key_wait`).
- A new account already has an ingest license key, and `keySearch` reads it back with the user key.
- The `<account> - ReadOnly` group is created and granted `read_only`.

Org state as read on 2026-10-30 (read-only queries, no mutations):
- Exactly two lab accounts exist: `INSTRUQT_LAB 01` = <lab-01-account-id> and `INSTRUQT_LAB 02` = <lab-02-account-id>.
  The earlier duplicates <old-duplicate-account-id-1> and <old-duplicate-account-id-2> no longer exist.
- `INSTRUQT_LAB 01 - ReadOnly` holds only `Read Only` on <lab-01-account-id>, and `02` only `Read Only` on <lab-02-account-id>; both groups have no members.
- Pool users `labpool+001` and `+002` exist, are free (in no group), and their invites are not yet known to be accepted.
- The `Admin` group (the key's user is in it) holds `All Product Admin` on both lab accounts plus org-level Organization Manager.

State on 2026-10-30, after the grant fix (read-only `accounts status`):
- `INSTRUQT_LAB 02 - ReadOnly` holds `All Product Admin` on <lab-02-account-id> only and is claimed by `labpool+002`; `labpool+001` is free.
- `INSTRUQT_LAB 01 - ReadOnly` holds NO grant; it needs `./provision.sh accounts create 2` (with `LAB_READONLY_ROLE=all_product_admin`, now set in `.env`) before anyone is mapped to it.
- Both pool users are `Full platform`, invites accepted (`emailVerificationState: VERIFIED`).
- Login as 002 before its group had a grant: "You don't have access to an account in this organization". Key creation as 001 in a group with no grant: "You do not have permission to create this key". Both explained by the missing grant, not by the role.

Not yet exercised or verified:
- `apiAccessCreateKeys` (never needed so far, because the key already exists).
- `pair claim` and `lab/bootstrap.sh` against the real org (adding a pending-invite user to a group).
- Pool-user invite delivery to a Google Group via plus-addressing (`labpool+test@example.com`), accepting invites, the shared password.
- `accounts destroy` (two-step cancel), the Selenium EU hosts, and the Apps Script against real Gmail.
- An actual Instruqt track run on a stock image.
- Logging in as a pool user to see the account switcher list only their own account (the grant structure says it will; the UI is unchecked).

## Learner role and account visibility (verified 2026-10-30)

Read from the org's role permission sets (`customerAdministration.permissions`, filter `roleId`), not from docs.
Role ids are org-wide standard roles: `read_only` 1252, `standard_user` 1253, `all_product_admin` 1254.

| Feature the masterclass uses | `read_only` | `standard_user` | `all_product_admin` |
| --- | --- | --- | --- |
| Workflow Automation definitions, runs, schedules | read | full | full |
| Alert policies and conditions | read | read | full |
| Destinations, channels, alert workflows (Applied Intelligence) | read | read | full |
| Change Tracking change events | read | modify | modify |
| User API keys (for self) | full | full | full |
| License keys | none | read | manage |

- **Decision: grant `all_product_admin` to the learner group**, on that group's one account only.
  The masterclass has learners create alert policies, conditions, destinations, channels and alert workflows, which `standard_user` can only read.
  A custom role (`standard_user` plus Alerts and Applied Intelligence modify/delete) is the tighter alternative and was not chosen.
- **Visibility is limited by grant scope, not by role.** A user sees only the accounts their groups hold grants on.
  It holds as long as each lab group has exactly one `ACCOUNT`-scoped grant, no `ORGANIZATION`-scoped grant, and the pool user belongs to no other group (a free user has no groups by definition).
- **Learners can mint their own `NRAK-` user key** under any of these roles, scoped to their user and so to their one account.
  That is how the masterclass's `lab/wire-credentials.sh` gets a user key; the instructor's Organization Manager key must never reach the learner.
- **Risk with `all_product_admin`:** it can manage license keys, so a learner can delete their account's ingest key and break the next lab that claims the account.
  Teardown, or a claim-time check, should confirm the key still exists.
- `.env` now has `LAB_READONLY_ROLE=all_product_admin` (2026-10-30); lab 02's group holds it, lab 01's does not yet.
- Granting permissions or changing group membership is blocked for the agent by the Claude Code auto-mode classifier; the user runs those commands.
- **Pending (blocked):** changing the default from `read_only` in `provision.sh`, `.env.example`, README and tests.
  The Claude Code auto-mode classifier refused the edit as a permission escalation, so the user must make it or allow it.
  Setting `LAB_READONLY_ROLE=all_product_admin` in `.env` is enough for the code; a rename to `LAB_LEARNER_ROLE` is optional tidying.
- **Pending (needs the user's go-ahead):** grant role 1254 to the two existing groups on <lab-01-account-id> and <lab-02-account-id>, and optionally revoke `read_only`.
  Re-running `accounts create` with the new role adds the grant but leaves `read_only` in place.
- Keep the group suffix ` - ReadOnly` even though the role is no longer read-only: `bootstrap.sh` derives the account name from it, and renaming means recreating the groups.

## Account scrub (built 2026-10-30)

Lab accounts and pool users are reused, so whatever a learner creates would otherwise reach the next learner, and `wfa_bootstrap.py` reuses objects that already exist by name.
Decision (user): wipe everything in the lab account, at lab end automatically and on demand with `accounts scrub`.
- The `newrelic` CLI (0.99.6) cannot do this: it has only `apiAccess apiAccessDeleteKeys` and raw `nerdgraph query` (which hides errors), with no alert commands and no entity delete.
  The scrub calls NerdGraph through `gql`.
- Order, dependents first: Workflow Automation schedules and definitions (ACCOUNT scope only), alert workflows (`deleteChannels: true`), channels, destinations, muting rules, policies, open issues (`aiIssuesResolveIssue`), top-level dashboards, synthetic monitors, every other entity (`entityDelete` with `forceDelete`, retried with `agentApplicationDelete(force)` for APM apps), then pool users' USER keys (`apiAccessDeleteKeys`).
- Kept: ingest keys, keys of non-pool users (instructors), the caller's key, AIOPS entities (they are index entries for the alert objects deleted earlier), the account and group, and NRDB data.
- Guard: refuses any account not named `<LAB_ACCOUNT_PREFIX> NN`; `accounts scrub` skips a claimed account unless `--force`.
- Every list query and every mutation's argument types were checked by read-only introspection, and `accounts scrub --all --dry-run` ran clean against the real org on 2026-10-30.
  It found Challenge 2 leftovers in `INSTRUQT_LAB 01` (alert workflow, channel, email destination, policy, 14 entities, one `labpool+002` key).
- Not yet run for real (needs the user's go-ahead): whether `entityDelete` accepts INFRA HOST and CONTAINER and BROWSER entities, and whether the Organization Manager key may delete a pool user's key.
- Deleting an entity while its agent still reports recreates it, so the track cleanup must stop data first (`docker compose down`, `systemctl stop newrelic-infra`) before the teardown runs.

## Known issues and gotchas

- **Duplicate accounts are dangerous.** An early run created <old-duplicate-account-id-1> and, on re-run, <old-duplicate-account-id-2>, both named `INSTRUQT_LAB 01` (both gone as of 2026-10-30).
  The lab resolves the account by name and takes the first match.
  `pair claim` warns when names are duplicated.
- **Grants are not a field on groups.** `MultiTenantIdentityGroup` has no `roles` field; grants come from `customerAdministration.grants(filter: {organizationId, groupId})`, returning `role { id }` (Int) and `scope { id type }` (String id, type `ACCOUNT` or `ORGANIZATION`).
  `_has_grant` queried `roles` on the group, so it always errored and `accounts create` always re-granted (harmless, since grant treats already-exists as success).
  The two copies were fixed separately on 2026-10-30; the merged version uses the shared helper below.
  Now `lib/common.sh` `group_account_grants <group id>` reads `grants` (paginated, ACCOUNT scope only), and `_has_grant`, `accounts status`, and `bootstrap.sh` all use it; both test stubs answer the real shape.
- **Grants can disappear outside the kit.** On 2026-10-30 both lab groups were found with zero grants (lab 02's `Read Only` had been there hours earlier); nothing in the kit revokes grants, so it was most likely a UI edit.
  The Admin group's own `All Product Admin` on the lab accounts is easy to mistake for the lab group's grant in the UI.
  `accounts status` now has a `GROUP-GRANT` column (`NONE` plus a warning when a group holds nothing on its account); `bootstrap.sh` refuses such a group and releases the claim; `teardown.sh` warns when the account's license key is gone.
- **`newrelic nerdgraph query` (CLI 0.99.6) prints `{}` for failed queries and for introspection**, hiding the error.
  For diagnosis, send the query with `curl` to `https://api.newrelic.com/graphql`, which returns the `errors` array.
- **The New Relic MCP server has no user, group, role or grant tools**, only observability ones (NRQL, entities, alerts, logs); use NerdGraph for this kit.
- Filters on `customerAdministration.groups` and `users` require `organizationId` and `authenticationDomainId` respectively; an empty filter is rejected.
- Resume after a partial failure can create duplicates if the account is not yet listed.
  Wait a minute or two before re-running.
  A local state file recording created ids was proposed and not built.
- `--dry-run` blocks all mutations, so a successful dry run does not validate mutation shapes.
- Schema error hints can be wrong (`region_code`).
  Introspect the schema (read-only) before guessing: `__schema { mutationType { fields { name args { ... } } } }`.
- `provision.sh` auto-sources the real `.env`.
  Tests therefore run a temp copy of `provision.sh` and `lib/`, so a real `.env` never leaks in.
- jq `--arg` name must match the `$name` used in the program (an earlier `$cursor` bug).
- Plus-addressing only works if the base address exists as a mailbox, group or alias, otherwise the invite bounces.
- Collision policy differs from MARS: the claim checks both the user side and the group side and has no smallest-id tie-break.
- Generated or local files that must stay out of git: `.env`, `dist/`, `invites.json` (holds the password and accept links), `selenium/.venv/`, `__pycache__/`, `.hypergrep/`.

## Masterclass wiring status (checked 2026-10-30)

- `track_scripts/setup-wfa-infra` writes the built `setup-wfa-infra` into `/usr/local/bin/pool-lab-setup` through a quoted heredoc, with `set +x`, and runs it.
  The `profile.d` export of `NEW_RELIC_ACCOUNT_ID` / `NEW_RELIC_LICENSE_KEY` runs at the end of that script.
  The heredoc body is identical to a fresh `build-lab-scripts.sh --vm wfa-infra` build; rebuild and re-paste after any `lib/` or `lab/` change.
- `track_scripts/cleanup-wfa-infra` runs `docker compose down`, then the inlined built teardown (identical to a fresh build).
- `01-setup-and-instrument/setup-wfa-infra` is back to the image pull only; the dead claim copy after `exit` is removed.
- `config.yml` env and secret indirection (`NR_DEVREL_LAB_API_KEY`, `NR_DEVREL_LAB_USER_PASSWORD`) match the bootstrap's env contract; the secrets' existence in Instruqt is unchecked.
- `lab/wire-credentials.sh` uses values already in the environment, so with the `profile.d` export it asks only for the learner's `NRAK-` key.
- Missing: challenge 01 copy still tells learners to find the license key and account ID themselves, and does not show the login (`[[ Instruqt-Var key="POOL_USER_EMAIL" hostname="wfa-infra" ]]`, `LAB_USER_PASSWORD`).
- Unchecked: whether Instruqt exposes the `NR_DEVREL_LAB_API_KEY` secret in learner terminals (`env | grep NR_DEVREL` on a test lab).
- An exhausted pool makes `pool-lab-setup` exit 1, which fails the whole launch; there is no fallback to manual key entry.
- Before testing: `./provision.sh accounts create 2` (lab 01 has no grant) and `./provision.sh users free labpool+002@example.com`.

## Suggested next steps

1. Switch the learner role to `all_product_admin` (see "Learner role and account visibility"), then, with the user's approval, grant it to the two existing lab groups.
2. Send a test mail to `labpool+test@example.com`, then accept the two pending invites by hand and set `POOL_PASSWORD`.
3. Run `./provision.sh pair claim --dry-run`, then a real `pair claim` and `users free`, then `lab/bootstrap.sh` and `lab/teardown.sh` locally.
4. Scale up: `users create` with `POOL_USER_COUNT=20`, `accounts create 20`, accept invites, `users validate-passwords`.
5. Build the track scripts (`build-lab-scripts.sh --vm <name>`), merge `instruqt/config.snippet.yml`, and test on a stock-image Instruqt track.
   For the masterclass (VM `wfa-infra`):
   - the built `setup-wfa-infra` / `cleanup-wfa-infra` would overwrite the track's existing scripts of the same name, so merge or chain them, do not copy;
   - the track setup runs `set -x` into `/var/log/wfa-setup.log`, so the claim must run with tracing off or the Organization Manager key and license key land in the log;
   - the track's `config.yml` has no `environment:` or `secrets:` yet, and the snippet assumes VM name `lab`.
6. After the workshop run `accounts destroy`; phase 2 manifest mode is optional.

## If ported to another repo

Copy the whole `pool-lab/` directory.
Its only link to the original repo is documentation: `SUBACCOUNT-POOL-REUSE-REPORT.md` (copied into `pool-lab/`) explains how MARS creates sub-accounts and maps pool users.
Re-create `.env` from `.env.example` and re-run the four test suites first.
