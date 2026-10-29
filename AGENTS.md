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
- **Canonical APM app names:** `wfa-shop-api`, `wfa-controller`, `wfa-loadgen`, identical to
  the container names. Literals in compose (no `${...}` interpolation, never from `.env`),
  matched by the entrypoint defaults, the controller's `TARGET_APP_NAME`, and the lab's
  Terraform and checks. GHCR image names (`workflow-automation-app:v1` etc.) are package
  names and stay.
- **`compose_up` passes a minimal env** (`PATH`, `HOME`, `DOCKER_*`, `APP_TAG`), never
  `os.environ`: shell vars beat `.env` in compose interpolation, and the controller's own
  `NEW_RELIC_APP_NAME` once leaked into every `shop-api` it recreated.
- **No credentials in git.** `.env` is ignored. Only `.env.example` is tracked.
  Never copy files from the older `workflow-app-testing` repo's `infra/` or `.env`.
- **Images are built and published by CI, never by hand.** `.github/workflows/publish.yml`
  builds and pushes every GHCR image (app `v1`/`v2`, controller, loadgen) on push to `main`
  or a `lab-*` tag. Do not run `docker push`; committing and pushing to `main` is the release.
  `scripts/build-images.sh` is for local testing only.
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
