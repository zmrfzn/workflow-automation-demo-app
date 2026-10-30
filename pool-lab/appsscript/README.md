# parse-invitations — pool-lab Apps Script

This file is optional.
You can accept the pool-user invites by hand instead (see "Accept the invites manually" in `pool-lab/README.md`).
Use this script only if you want `pool-lab/selenium/pool_users.py` to accept them for you.

## Purpose

`parse-invitations.gs` reads the New Relic invitation emails for the pool users from a Gmail label.
For each pool user `${POOL_EMAIL_PREFIX}NNN@${POOL_USER_DOMAIN}` it extracts the address and the Accept Invitation link, adds the shared password, and emails you a JSON array.
Each element is exactly:

```json
{
  "to": "labpool+001@example.com",
  "accept_link": "https://login.newrelic.com/invitations/...",
  "password": "<shared password>"
}
```

Save that JSON as `pool-lab/invites.json`, which `pool-lab/selenium/pool_users.py` reads.

## How this differs from automation/appsscript

- No workload names.
  The 100-entry `WORKLOAD_NAMES` table is gone, and the output has no `workload_name` field.
- The Gmail label, subject filter, address prefix, domain, and lookback window are all constants in one CONFIG block.
- Only addresses of the form `${POOL_EMAIL_PREFIX}NNN@${POOL_USER_DOMAIN}` are accepted, matched with a properly escaped, anchored, case-insensitive regex.
  The address is read from `To`, then `Cc`, then `Bcc`, then `X-Original-To` / `Delivered-To` lines in the raw headers, and the log says which fallback fired.
- The fixed one-hour `CUTOFF_DATE` is replaced by `LOOKBACK_HOURS` (default 24), computed on every run.
- If several invites exist for the same address (re-sent invites), the newest one wins.
  Output is sorted by address.
- The password is one shared constant, `POOL_USER_PASSWORD`, instead of being parsed from a `+password` address.
  If it is empty the script aborts and includes no user.
- The run log shows parsed, skipped-old, and skipped-no-link counts, plus which of the expected addresses `001..POOL_USER_COUNT_EXPECTED` have no invite.
- `extractAcceptLink` is unchanged except that its fallback also accepts `login.eu.newrelic.com`.

## Configuration

Edit the CONFIG block at the top of `parse-invitations.gs`.

| Constant | Default | Description |
| --- | --- | --- |
| `GMAIL_LABEL` | `"lab-invites"` | Gmail label your filter applies to the invite emails |
| `EMAIL_SUBJECT_FILTER` | `"has invited you to New Relic"` | Subject substring to match |
| `POOL_EMAIL_PREFIX` | `"labpool+"` | Example only: set your own, including the trailing `+` |
| `POOL_USER_DOMAIN` | `"example.com"` | Domain of the pool-user addresses |
| `POOL_USER_PASSWORD` | `""` | The shared password for every pool user (required) |
| `MAX_THREADS` | `500` | Maximum number of Gmail threads to read |
| `LOOKBACK_HOURS` | `24` | Ignore invites older than this many hours |
| `POOL_USER_COUNT_EXPECTED` | `20` | Number of pool users you expect, used to report missing invites |

The real subject is "Your `<org name>` admin has invited you to New Relic", and the org name is not known in advance.
That is why the default is a substring.
If you want stricter matching, paste a real subject from one of your invites into `EMAIL_SUBJECT_FILTER`.

## Setup

1. Create a Google Group whose address is the part of your prefix before the `+`, for example `labpool@example.com`.
   You must own the group and be a member, so that mail to `labpool+001@example.com` is delivered to the group and reaches your inbox.
   Check this by sending a test mail to `labpool+test@example.com` before you create the pool users.
2. In Gmail, create a label named `lab-invites`.
3. Create a Gmail filter on `to:labpool+` (Gmail: search bar, **Show search options**, **To**, **Create filter**) that applies the `lab-invites` label.
   Optionally tick **Also apply filter to matching conversations**.
4. Go to [script.google.com](https://script.google.com) and create a new project.
   Replace the contents of `Code.gs` with the contents of `parse-invitations.gs`, then set the CONFIG block (at least `POOL_USER_PASSWORD`) and save.
5. Create the pool users so the invite emails are sent, then wait for them to arrive.
6. Select the `parseInvitations` function and click **Run**.
7. On the first run only, approve Gmail access.
   Click **Review permissions** and select your Google account.
   You may see "Google hasn't verified this app", so click **Advanced** then **Go to (project name) (unsafe)**, then click **Allow**.
   Later runs do not prompt.
8. Open **View → Logs** to read the summary and the list of missing addresses.
   If any are missing, fix the cause (for example the filter or the label), and run again.
9. The script emails you the JSON.
   Copy it from that email and save it as `pool-lab/invites.json`.

## Security

The emailed JSON necessarily contains the shared password.
The password is never written to the Apps Script log.
Delete the results email (and empty the trash) once `pool-lab/invites.json` is saved.
`pool-lab/invites.json` itself holds the password and the one-time accept links, so do not commit it.

## No GCP project needed

The script runs in the default Apps Script project that Google creates for it.
You do not need to create or link a Google Cloud (GCP) project, enable any API, or deploy a web app.
`doGet()` is only there if you later choose to deploy it, and it is not required.
