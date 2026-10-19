# workflow-automation-demo-app

Sample stack for the New Relic **Workflow Automation masterclass** (Instruqt lab).
It gives the lab something to break and something to fix.

| Service | Port | Role |
|---|---|---|
| `shop-api` | 5000 | Flask app with the New Relic APM agent. Runs as release `v1` (healthy) or `v2` (bad deploy) |
| `redis` | 6379 | Cache used by `/api/products` |
| `loadgen` | none | Steady traffic so error rate and latency produce alertable data |
| `controller` | 5001 | Deploys and rolls back `shop-api`; the endpoint Workflow Automation calls |

## Releases

One source, two images (`RELEASE` build arg). `app/releases/v2.py` holds the bugs: a
slow upstream timeout, `KeyError`, `AttributeError`, `NameError`, `ValueError`, and a
cache bypass on `/api/products`. Rolling back runs the `v1` image, so the change is
visible in the app page, the controller page, and APM change tracking.

## Controller API

Writes need the header `X-Rollback-Token: <ROLLBACK_SECRET>`. The controller refuses
every write when no secret is configured.

| Endpoint | Method | Auth | Effect |
|---|---|---|---|
| `/` | GET | none | Status page: running version and action history |
| `/status` | GET | none | JSON version and history |
| `/health` | GET | none | Liveness |
| `/deploy` | POST `{"version":"v1"\|"v2"}` | token | Switch release (default `v2`) |
| `/rollback` | POST `{"reason","triggered_by"}` | token | Switch to `v1` |
| `/reset` | POST | token | `v1` plus Redis flush |

Write responses are a verification payload:
`{action, status, version_before, version_after, verified, noop, nr_marker, request_id}`.
A second rollback while on `v1` returns `verified:true, noop:true`.

## Run locally

```bash
scripts/build-images.sh                     # builds v1, v2, controller, loadgen
printf 'ROLLBACK_SECRET=changeme\n' > .env
docker compose up -d
APP=http://localhost:5000 CTL=http://localhost:5001 scripts/smoke-test.sh
```

On macOS, port 5000 is used by AirPlay. Add a git-ignored `docker-compose.override.yml`
that remaps `shop-api` and `controller` ports.

Unit tests (no Docker, no New Relic):

```bash
python3 -m venv .venv && .venv/bin/pip install flask redis requests
.venv/bin/python -m unittest discover -s tests
```

## Lab helpers

`lab/` is what a learner runs on the Instruqt VM: `wire-credentials.sh` (writes `.env`),
`install-agents.sh` (guided New Relic install, interactive), `start.sh` (stack up, wait for health), `stop.sh`
(stops `loadgen` only, to pause traffic between challenges; `start.sh` resumes it), `debug.sh` (status, plus `restart [service]`, `reset`
and `logs [service]`), and the optional `install-redis-integration.sh` (`nri-redis` for the Redis container; Redis is not needed by the lab).
The APM agent ships inside the `shop-api`, `controller` and `loadgen` images, each as its own application
(`wfa-shop-api`, `wfa-controller`, `wfa-loadgen`, the same as the container names), and starts when a license key is set.
The names are literals in `docker-compose.yml`, not read from `.env`.

## Publishing

`.github/workflows/publish.yml` builds `workflow-automation-app:{v1,v2}`,
`workflow-automation-controller:1` and `workflow-automation-loadgen:1` to GHCR. The
packages must be public so the lab VM can pull anonymously.
