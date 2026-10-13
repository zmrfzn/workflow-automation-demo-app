# AGENTS.md

Guidance for AI agents working in this repo. It is the app side of the Instruqt lab in
`devrel-instruqt-workshops/devrel-workflow-automation-masterclass` (see that
directory's `AGENTS.md` and `Workplan.md`). Changes here are usually paired with a
change there.

## Rules that matter

- **Rollback must stay a real release change.** `v2` is a different image with real code
  bugs in `app/releases/v2.py`. Do not turn the bugs into env flags or runtime toggles.
- **`v1` must stay clean.** `scripts/smoke-test.sh` and `tests/` assume v1 never errors.
- **Controller safety.** Fixed version allow-list (`v1`, `v2`), one fixed service name,
  argument lists only (never a shell), token required for every write, fail closed when
  `ROLLBACK_SECRET` is empty. It mounts the Docker socket, so keep it narrow.
- **Idempotent actions.** Repeating a rollback returns `noop:true, verified:true`.
- **One controller worker.** The action lock and history are in process memory.
- **Canonical APM app name:** `workflow-automation-app`, in compose, the entrypoint, the
  controller, and the lab's Terraform and checks.
- **No credentials in git.** `.env` is ignored. Only `.env.example` is tracked.
  Never copy files from the older `workflow-app-testing` repo's `infra/` or `.env`.
- Stage by explicit path. Commits carry no co-author or attribution trailer.

## Verify before claiming done

| Target | Command |
|---|---|
| Unit tests | `python3 -m unittest discover -s tests` (needs flask, redis, requests) |
| Python | `python3 -m py_compile app/app.py app/releases/*.py controller/controller.py loadgen/loadgen.py` |
| Shell | `bash -n lab/*.sh scripts/*.sh app/entrypoint.sh` |
| Compose | `docker compose config -q` |
| Containers | `scripts/build-images.sh`, `docker compose up -d`, then `scripts/smoke-test.sh` |

Needs a live New Relic account and cannot be confirmed offline: APM reporting, the
change-tracking marker (`changeTrackingCreateDeployment`), infrastructure agent install,
log forwarding. Report these as unverified until a paid-account dry run.
