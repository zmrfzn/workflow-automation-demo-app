# Reusing sub-account creation and pool-user mapping outside MARS

## Purpose

This report documents how the MARS track creates per-team New Relic sub-accounts and maps them to a pre-created pool of read-only users.
It also records what has to change to reuse that mechanism against a different, non-MARS New Relic org, on a stock Instruqt image (no custom VM image).

Status: research only.
No code has been changed, and no New Relic API call was made while producing this report.
Items marked **(inferred)** are not stated by the code.
Items marked **(unverified)** could not be checked.

---

## 1. How a sub-account is created and removed

The Terraform module `nr_account` is not in this repo.
It lives in `github.com/newrelic/opentelemetry-demo` under `newrelic/terraform/nr_account/`.
`image-setup/setup-image.sh:83` pins the commit (`OTEL_DEMO_COMMIT`, currently `7560bd5bb340537e53de0c76779b1a86d76db2d9`), and `:109-114` clones it to `/opt/opentelemetry-demo` in the VM image.
The module contains `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `group_role_grant.sh` and `group_role_revoke.sh`.
`versions.tf` requires Terraform >= 1.4 and the `newrelic/newrelic ~> 3.98` provider.
These module files were read from the pinned commit via `gh api`, so the module description below is verified.

### Create (`mars-program/track_scripts/setup-k8s:226-268`)

The create step runs inside a retry loop of up to 10 attempts, with a 60 second sleep between attempts.

1. **Phase 1:** `terraform apply -target=newrelic_account_management.subaccount` creates the sub-account under the parent account, named `var.subaccount_name` (`:231-233`).
2. **Phase 2:** `terraform apply -target=newrelic_api_access_key.license_key` (`:235-237`).
   Its `depends_on` pulls in the following, in order:
   - the data sources `newrelic_authentication_domain.admin_auth_domain` (name "Default") and `newrelic_group.admin_group`;
   - `terraform_data.admin_access_grant`, which runs `group_role_grant.sh <api_key> <region_host> <group_id> <role_name> <account_id>`;
   - the `newrelic_api_access_key.license_key` itself (`INGEST` / `LICENSE`, named "OpenTelemetry Demo License Key").
3. `group_role_grant.sh` looks up the role id, runs `authorizationManagementGrantAccess` for the admin group, then polls `actor.account(id:)` every 10 seconds, up to 60 times, until the API key can see the new account.
   This propagation wait is the reason for the long retry loop.
4. The readonly `newrelic_user` / `newrelic_group` resources inside the module are skipped, because `readonly_user_email` is null.
   Pool assignment replaces them.
5. Outputs `account_id` and `license_key` are read at `:253-264` and persisted as agent variables `NEW_RELIC_ACCOUNT_ID` and `NEW_RELIC_LICENSE_KEY` (`:266-267`).

The retry loop aborts immediately if the log matches `Invalid credentials|401|Unauthorized` (`:244`).
A stray "401" in Terraform output would also trigger that abort.

### Account name

`setup-k8s:187` builds `ACCOUNT_NAME="${NR_SUBACCOUNT_NAME_PREFIX} ${INSTRUQT_TRACK_ID}-${INSTRUQT_PARTICIPANT_ID}"`.
`config.yml:10` sets the prefix to `'MARS - '`, which already ends in a space, so the real name contains a double space.
Nothing found depends on that, but it is not verified.
The name is persisted as agent variable `ACCOUNT_NAME` and exported as `TF_VAR_subaccount_name`.
The readonly group name and the cleanup both derive from it.

### State

Terraform state is local, in `nr_account/terraform.tfstate` inside the VM.
It is the only record of the account id, which cleanup reads back with `terraform output` (`cleanup-k8s:14`).
Cleanup does not use the `NEW_RELIC_ACCOUNT_ID` agent variable.
If the VM is lost before cleanup, the account is orphaned.
`scripts/review-mars-state.sh` is the existing sweep for stale tracks.

### Teardown (`mars-program/track_scripts/cleanup-k8s:129-159`)

1. `cleanup-nr-account.sh` runs with `TF_AUTO_APPROVE=true`, which runs `terraform destroy` if state exists.
   On destroy, `group_role_revoke.sh` runs, the license key is removed, and the sub-account is cancelled.
2. A second call, `mutation { accountManagementCancelAccount(id: <id>) { id isCanceled } }`, is made via curl (`:146-156`).
   New Relic needs two cancellation steps to fully delete an account.
3. Pool-user release happens earlier in the same script (`:81-116`), see section 2.

### Credentials

The key in `NR_API_KEY_SECRET` (secret `NR_MARS_GAMEDAY_API_KEY`) is a NerdGraph **User** API key.
The module's `variables.tf` says it needs Organization Manager permissions and must belong to a user in `admin_group_name`.
That group must be grantable `all_product_admin`, because the role has to allow license-key creation.
The same key is used for the `customerAdministration` user and group calls, role lookups and grants, and `accountManagementCancelAccount`.
The exact minimum permission set is **(unverified)**.

A separate Insert/License key (`NR_MARS_GAMEDAY_LICENSE_KEY`) is used only for answer-attempt telemetry.
It is not needed for sub-account creation.

### Terraform variables

| Variable | Set where |
| --- | --- |
| `TF_VAR_newrelic_api_key` | `setup-k8s:190`, `cleanup-k8s:12`, from the secret named by `NR_API_KEY_SECRET` |
| `TF_VAR_subaccount_name` | `setup-k8s:193`, `cleanup-k8s:13` |
| `TF_VAR_newrelic_parent_account_id` | `config.yml:13` |
| `TF_VAR_admin_group_name` | `config.yml:12` |
| `TF_VAR_readonly_role_name` | `config.yml:14`, used by the shell grant for the readonly group, not by the `nr_account` apply |
| `TF_VAR_newrelic_region` | Not set anywhere, so it defaults to US |
| `TF_VAR_admin_authentication_domain_name`, `TF_VAR_admin_role_name`, `TF_VAR_readonly_authentication_domain_name` | Not set, defaults "Default", "all_product_admin", "Default" |

---

## 2. How a pool user is mapped to a sub-account

The mapping is not Terraform.
It is NerdGraph calls in `setup-k8s:280-615`.
Pool users are permanent in the New Relic org and are either **free** (no group memberships) or **in use** (member of a per-track `<account name> - ReadOnly` group).
See also `docs/pool-user-management.md`.

1. Resolve the auth domain (name "Default" unless overridden), `:298-314`.
2. Query all users in the domain and keep those whose email starts with `NR_USER_POOL_PREFIX` and that have no groups (`:342-369`).
   Users already tried and lost to a race are excluded.
3. Pick one at random (`:381-387`).
4. Find-or-create the group `"${ACCOUNT_NAME} - ReadOnly"` (`:389-438`).
   The lookup-first step exists because deletes are eventually consistent, so a rolled-back group could still be visible when the retry tries to create it again.
5. Run `group_role_grant.sh` to give the group `read_only` (the value of `TF_VAR_readonly_role_name`) on the new sub-account (`:440-447`).
6. Add the user to the group with `userManagementAddUsersToGroups` (`:449-463`).
7. Poll up to three times, one second apart, to confirm the user still belongs to only this group (`:465-491`).
   If the user now has more than one group, another track claimed them.
   Roll back (remove user, delete group), add the user id to a skip list, back off one to three seconds, and retry.
   The loop is bounded at 8 attempts (`:322-340`).
8. Create or find a custom role "SAI Read" (permission ids 12735, 12737, 12777, 12781, 14330, 14337) and grant it to the group (`:514-606`).
   This step is fatal on failure.
   The ids are described as stable in a code comment but are **(unverified)** for another org.
9. Persist `POOL_USER_ID`, `POOL_USER_EMAIL`, `POOL_GROUP_ID`, `USER_EMAIL`, `USER_NAME` as agent variables (`:608-615`).

Teardown (`cleanup-k8s:77-116`) removes the user from the group and deletes the group, which makes the user free again.

The shared pool password is not generated here.
It is set when invites are accepted (section 3) and surfaced to the participant through the Instruqt secret `MARS_USER_PASSWORD` (`config.yml:27`, `setup-k8s:178-184`).

---

## 3. How pool users are created and verified

### Lifecycle

1. `scripts/manage-pool-users.sh create` (`:164-214`) loops `001..POOL_USER_COUNT`, builds `mars+${i}@${POOL_USER_DOMAIN}` (`:177`), and calls the NerdGraph mutation `userManagementCreateUser` (`:191`) with `userType: "FULL_USER_TIER"` in the Default auth domain.
   This mutation is the only email trigger in the repo.
   The code never says an email is sent, so that part rests on the stated premise.
2. Accepting the invite and setting the password happens outside `manage-pool-users.sh`, and is semi-manual:
   - `automation/appsscript/parse-invitations.gs` searches Gmail (`:128`) and finds the "Accept Invitation" link (`extractAcceptLink`, `:205-214`).
     For recipients matching `^mars\+\d+@` it uses the hardcoded shared `POOL_USER_PASSWORD` (`:21-22`, `:148-153`).
   - It emails the resulting JSON to the script owner (`:182-187`), who saves it as `automation/users.json` (format in `automation/users.example.json`).
   - `gameday.py` default mode loads `users.json` (`:608`).
     `accept_invite()` (`:67-126`) opens the link, fills the password field and submits.
     If the link says the invite is invalid, or there is no password field, it treats the invite as already accepted.
3. Rotation: `manage-pool-users.sh reset-passwords` runs `gameday.py --reset-pool-passwords`, which logs in with the current password and changes it at `login.newrelic.com/passwords/change`.
   `validate-passwords` is the read-only login check.
4. The Instruqt secret `MARS_USER_PASSWORD` must always be updated together with the New Relic passwords.

### Why the verification email goes to the "mars" group

The repo never mentions a Google Group, alias or catch-all.
The routing is **(inferred)** to be Google Workspace plus-addressing: mail to `mars+042@example.com` is delivered to the `mars@example.com` mailbox or group.
Members see it in Gmail, where the label `mars` catches it (`automation/README.md:23-37`).
This is **(unverified)**.

### Everything coupled to "mars"

| Where | What |
| --- | --- |
| `scripts/manage-pool-users.sh:42` | `POOL_EMAIL_PREFIX="mars+"`, used as the `startswith` filter in `fetch_pool_users` (`:111`) |
| `scripts/manage-pool-users.sh:177` | Prefix hardcoded again in `email="mars+${i}@..."`, does not use the variable |
| `scripts/manage-pool-users.sh:178` | `name="MARS User ${i}"` |
| `mars-program/config.yml:7` | `NR_USER_POOL_PREFIX: "mars+"`, read at `setup-k8s:322` |
| `automation/selenium/gameday.py:420`, `:448` | `f"mars+{i:03d}@{domain}"` for reset and validate |
| `automation/pool-monitor/pool-monitor.js:31` | `POOL_EMAIL_PREFIX = "mars+"` |
| `instructor/dashboards/mars-pool-users.json:9`, `automation/pool-monitor/dashboard.json:8` | Dashboard queries |
| `automation/appsscript/parse-invitations.gs:12` | `GMAIL_LABEL = "mars"`, used in the query at `:128` |
| `automation/appsscript/parse-invitations.gs:14` | `EMAIL_SUBJECT_FILTER = "Your NR_MARS admin has invited you to New Relic"`; "NR_MARS" is **(inferred)** to be the name of the sending org |
| `automation/appsscript/parse-invitations.gs:21` | `POOL_USER_PATTERN = /^mars\+\d+@/i`; `message.getTo()` can return `Name <addr>`, in which case the `^` anchor would not match **(unverified)** |
| `automation/appsscript/parse-invitations.gs:22` | `POOL_USER_PASSWORD`, the shared password constant |
| `automation/appsscript/parse-invitations.gs:24-125` | 100 hardcoded `WORKLOAD_NAMES` assigned per parsed email, irrelevant for pool users but still attached |
| `automation/README.md:23-37` | Documents subject `Your GameDay admin has invited you to New Relic`, which does not match the script; one of them is stale |

Already generic, no change needed:
- the `" - ReadOnly"` group suffix (derived from the account name);
- `POOL_USER_DOMAIN` (default `example.com`, already configurable);
- the `gameday.py` login selectors and URLs.

### Options to redirect verification mail without breaking MARS

- **A. Different local-part, same domain** (for example `othergd+001@example.com`).
  Needs a new Google Group or mailbox `othergd@example.com` in Workspace admin (outside this repo) and a new Gmail label and filter for whoever runs the Apps Script.
  MARS is untouched.
  Lowest risk.
- **B. Different domain.**
  `POOL_USER_DOMAIN` already supports it, but it needs a domain or alias and a group in Workspace.
  Only worthwhile if the other org cannot use `example.com`.
- **C. Same group, separated by `+tag` or a Gmail filter on the `To` header.**
  The MARS group still receives the mail, so this fails the requirement.
  Not recommended.

For any option, the other org's New Relic instance sends the invite, so its sender and subject may differ from `noreply@newrelic.com` and the NR_MARS subject.
Check a real sample before reusing the Gmail filters.

---

## 4. What the baked image provides, and the stock-image substitute

### Needed by the sub-account + pool-user path only

| Dependency | Baked at | Stock-image substitute |
| --- | --- | --- |
| `terraform` | `setup-image.sh:127-139` (HashiCorp apt repo) | Same apt block (needs `gnupg`, `lsb_release`) or the release zip; guard with `command -v` |
| `jq`, `curl` | `setup-image.sh` | `apt-get install`, guarded with `command -v` |
| `nr_account/` module and `group_role_grant.sh` | Clone at pinned commit, `chmod -R a+rw` (`:194-215`) | Shallow fetch of the pinned SHA (`init`, `remote add`, `fetch --depth 1 <sha>`, `checkout --detach`), or vendor the files into the new track (preferred) |
| Provider cache | `terraform init` on `nr_account` (`:228-240`) | `setup-k8s:126-134` already runs `terraform init` in the background when `.terraform/` is missing, and `:222-225` waits for it; reuse that |
| `agent_var_set` / `agent_var_get` | Baked in `mars-check-helpers` (`:936-974`) | Lift the inline copy at `setup-k8s:31-78` |
| `agent` CLI, `/opt/instruqt/bootstrap/host-bootstrap-completed` | Provided by Instruqt, not baked | Provided by Instruqt |

`yq` is used at `setup-k8s:151` but is never installed by `setup-image.sh`.
It is presumably in the k3s base image, which is **(unverified)** for a stock image.
If `yq` is missing, the process substitution fails silently and env vars from the agent store do not resolve.

No `TF_PLUGIN_CACHE_DIR` or other Terraform environment setup was found in either script.
The cache is just `.terraform/` inside the module directory.

### Needed only by the rest of MARS (leave out)

Helm charts, container-image pre-pull, k3s heal logic, `mars-prompt`, `scorecard-refresh`, `mars-details`, `mars-sre-agent`, `mars-dashboard-sync`, `k9s`/`kubens`/`stern`, the `opentelemetry-demo.yaml` patch, the `nr_browser` and `nr_resources` modules.

Documentation note: `CLAUDE.md` says `setup-k8s` sources `mars-check-helpers`, but `setup-k8s` still carries its own inline copy of `agent_var_set` / `agent_var_get`.
Only `cleanup-k8s` sources the baked helpers (`:5`).

---

## 5. Proposed design

These are proposals, not decisions.

### Pool-user creation (primary)

- Make the email prefix, user-name template, Gmail label, invite subject filter, recipient pattern and shared password configurable.
- Default every value to today's `mars+` setting, so MARS behaviour is unchanged.
- In `manage-pool-users.sh`: `POOL_EMAIL_PREFIX="${POOL_EMAIL_PREFIX:-mars+}"`, use it at `:177`, add a `POOL_USER_NAME_PREFIX`, and pass the prefix through to `gameday.py` in the env blocks at `:540-544` and `:579-582`.
- In `gameday.py`: read `POOL_EMAIL_PREFIX` from the environment and use it at `:420` and `:448`.
- In `parse-invitations.gs`: move the label, subject, password and pattern into one config block (or `PropertiesService.getScriptProperties()`), and build the recipient regex from the prefix with `+` escaped.
- Add the new variables to `scripts/.env.example`, `automation/selenium/.env.example` and the `scripts/README.md` table, and fix the stale subject text in `automation/README.md`.
- The other org needs its own `scripts/.env`, because the NerdGraph key and org are whatever `NEW_RELIC_API_KEY` belongs to.

### Stock-image bootstrap (secondary)

A self-contained `bootstrap-subaccount-and-pool-user.sh` and a matching `teardown-subaccount-and-pool-user.sh`, droppable into another track's `track_scripts/`.

Inputs (env vars and secrets):
- parent account id (`TF_VAR_newrelic_parent_account_id`);
- the name of the secret holding the NerdGraph user key (`NR_API_KEY_SECRET`);
- pool prefix (`NR_USER_POOL_PREFIX`) and auth domain name (default "Default");
- sub-account name prefix;
- `TF_VAR_admin_group_name` and `TF_VAR_readonly_role_name`;
- region (US or EU);
- the pinned module ref (if not vendored);
- an optional flag to skip the SAI Read step, off by default for non-MARS orgs.

Outputs (agent variables): `NEW_RELIC_ACCOUNT_ID`, `NEW_RELIC_LICENSE_KEY`, `ACCOUNT_NAME`, `NR_ORG_ID`, `POOL_USER_ID`, `POOL_USER_EMAIL`, `POOL_GROUP_ID`, `USER_NAME`.

Step order:
1. Install terraform, jq and curl if missing, and obtain the module.
2. Start `terraform init` in the background.
3. Wait for `host-bootstrap-completed`.
4. Validate secrets.
5. Fetch the org id.
6. Terraform Phase 1, then Phase 2, with the retry loop.
7. Read the Terraform outputs.
8. Resolve the auth domain.
9. Pool loop: pick a free user, find-or-create the group, grant, add the user, verify exclusivity.
10. SAI Read role create and grant (optional).
11. Set all agent variables.

Teardown, in order: remove the user from the group, delete the group, `terraform destroy`, second cancel call.

Run the bootstrap in the track-level `setup-<vm>` after the `host-bootstrap-completed` wait, and the teardown in `cleanup-<vm>`.
State is local to the VM, so teardown must run on the same VM and use the same module path.

My calls (not yet agreed):
- Vendor the `nr_account` module rather than cloning at runtime, after reviewing it.
- Do not hardcode `/opt`; pick one writable directory and `chmod a+rw` it, because check scripts may run as a different user.
- Skip the scorecard, SRE agent, dashboard sync and SAI Read role in the first version.

---

## 6. Other MARS-specific values to change for another org

- `mars-program/config.yml`: parent account id `<mars-parent-account-id>` (line 13), `NR_SUBACCOUNT_NAME_PREFIX` (10), `TF_VAR_admin_group_name` (12), `TF_VAR_readonly_role_name` (14), `NR_USER_POOL_PREFIX` (7).
  The admin group must exist in the Default auth domain and contain the key's user.
- Secret names `NR_MARS_GAMEDAY_API_KEY`, `NR_MARS_GAMEDAY_LICENSE_KEY`, `MARS_USER_PASSWORD`.
- Region and endpoint: the module accepts US, EU or JP, but `setup-k8s:294` maps only EU to `eu.newrelic`, so JP would be wrong.
  The curl calls hardcode `https://api.newrelic.com/graphql` (`setup-k8s:198`, `cleanup-k8s:41` and others), and `record_attempt` hardcodes the US insights collector.
  An EU parent org would need those changed.
- The parent account id is also reused by `record_attempt` (`setup-image.sh:1117`) and by Progression Lock (`CLAUDE.md`, not inspected here).
- The scorecard template contains the MARS org UUID `9f4fd2b4-23bf-407d-902c-f422717c8a81` (`setup-k8s:1054`).
  This is outside the sub-account mechanism.

---

## 7. Risks without the custom image

- **Time to ready.** apt, provider download and clone add roughly one to two minutes by estimate (not measured).
  This is small next to the up-to-10-minute grant propagation, which exists on the baked image too.
- **Hardcoded paths.** `WORK_DIR=/opt` is hardcoded at `setup-k8s:121` and `cleanup-k8s:8`.
  `/opt/opentelemetry-demo` paths also appear in the intro `check-k8s:34` and `cleanup-k8s:18`.
- **Secrets plumbing.** Secrets must be declared under `secrets:` in `config.yml` and mapped through `environment:`.
  Instruqt exposes them as env vars named after the secret, which the scripts read by indirection (`${!NR_API_KEY_SECRET}`).
- **SAI Read role.** Permission ids are unverified for another org, and the step is fatal on failure.
- **Orphans.** Per-VM local state means a lost VM leaves the sub-account and group behind.
- **Pool exclusivity** relies on the convention that a free user has no groups.
  Any other tool that adds a pool user to a group breaks it.
- **Error handling.** The ERR trap (`setup-k8s:82`) kills background PIDs and exits 1.
  Inside `until ( ... )`, `set -e` is suppressed, so the loop status is that of the last command (the Phase 2 `tee`, through `pipefail`).
  `agent_var_set` verifies by readback because the agent CLI exits 0 on failure.

---

## 8. Unverified items and open questions

Unverified:
- That `userManagementCreateUser` actually sends the invitation email.
- The Google Group, alias and Gmail filter configuration behind the "mars" routing.
- The real sender and subject of invites from the other org.
- The minimum permissions the API key needs.
- Whether `terraform destroy` works when the license key was never created.
- Whether `yq` exists on a stock Instruqt image.
- The upstream `cleanup-nr-account.sh`, `install-nr-resources.sh` and `common.sh`, which were not read.

Open question for the owner:
- For the new org's pool users, which email address or group will receive the New Relic verification emails, and does the owner control that mailbox or Google Group?
