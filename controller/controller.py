"""Controller: the remediation endpoint that Workflow Automation calls.

It deploys or rolls back shop-api by recreating the container from the v1 or v2
image, waits until the new release answers, writes a New Relic change-tracking
marker, and returns a verification payload.

Safety rules: a fixed allow-list of versions, one fixed service name, request input
never reaches a shell, and every write action needs the X-Rollback-Token header.
"""
import hmac
import json
import logging
import os
import subprocess
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timezone

import redis
from flask import Flask, jsonify, render_template_string, request

ALLOWED_VERSIONS = ("v1", "v2")
SERVICE = "shop-api"
PROJECT = os.environ.get("COMPOSE_PROJECT", "wfa")
COMPOSE_DIR = os.environ.get("COMPOSE_DIR", "/workspace")
APP_URL = os.environ.get("APP_URL", "http://shop-api:5000")
# The app whose change-tracking markers we write. Deliberately NOT NEW_RELIC_APP_NAME, which names
# this controller's own APM entity.
TARGET_APP_NAME = os.environ.get("TARGET_APP_NAME", "wfa-shop-api")
NERDGRAPH = "https://api.newrelic.com/graphql"
HEALTH_TIMEOUT = int(os.environ.get("HEALTH_TIMEOUT", "60"))
# Action history survives a controller restart when this points at a mounted volume.
# Lab checks read the history, so losing it on a recreate would fail them. Empty disables it.
HISTORY_FILE = os.environ.get("HISTORY_FILE", "")

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("controller")

_lock = threading.Lock()


def load_history():
    if not HISTORY_FILE:
        return []
    try:
        with open(HISTORY_FILE) as f:
            data = json.load(f)
        return data[-20:] if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def save_history():
    """Atomic write, so a crash mid-write never leaves a half file behind."""
    if not HISTORY_FILE:
        return
    try:
        tmp = HISTORY_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_history, f)
        os.replace(tmp, HISTORY_FILE)
    except OSError as e:
        log_event(event="history_save_failed", error=str(e))


_history = load_history()
_guid_cache = {}


def log_event(**fields):
    fields.setdefault("ts", datetime.now(timezone.utc).isoformat())
    log.info(json.dumps(fields))


def token():
    return os.environ.get("ROLLBACK_SECRET", "")


# ---- infrastructure calls (replaced in tests) ------------------------------

def compose_up(version):
    """Recreate shop-api from the requested release image."""
    # Minimal env, never os.environ: shell vars beat .env in compose interpolation, so this
    # process's own NEW_RELIC_* settings would leak into shop-api. Compose reads /workspace/.env.
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME") or k.startswith("DOCKER_")}
    env["APP_TAG"] = version
    subprocess.run(
        ["docker", "compose", "-p", PROJECT, "--project-directory", COMPOSE_DIR,
         "up", "-d", "--no-deps", "--force-recreate", SERVICE],
        check=True, capture_output=True, text=True, timeout=180, env=env)


def get_version():
    """Ask the running app which release it is. None when it does not answer."""
    try:
        with urllib.request.urlopen(f"{APP_URL}/api/status", timeout=3) as resp:
            return json.loads(resp.read()).get("version")
    except Exception:
        return None


def flush_cache():
    try:
        redis.Redis(host=os.environ.get("REDIS_HOST", "redis"), socket_timeout=2).flushall()
        return True
    except Exception as e:
        log_event(event="cache_flush_failed", error=str(e))
        return False


def nerdgraph(query, variables=None):
    key = os.environ.get("NEW_RELIC_API_KEY", "")
    req = urllib.request.Request(
        NERDGRAPH, data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={"Content-Type": "application/json", "API-Key": key})
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read())
    if body.get("errors"):
        raise RuntimeError(json.dumps(body["errors"]))
    return body["data"]


# ---- logic -----------------------------------------------------------------

def entity_guid():
    if "guid" in _guid_cache:
        return _guid_cache["guid"]
    data = nerdgraph(
        "query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid name } } } } }",
        {"q": f"name = '{TARGET_APP_NAME}' AND domain = 'APM' AND type = 'APPLICATION'"})
    entities = data["actor"]["entitySearch"]["results"]["entities"]
    if not entities:
        raise RuntimeError(f"no APM entity named {TARGET_APP_NAME} yet")
    _guid_cache["guid"] = entities[0]["guid"]
    return _guid_cache["guid"]


def fire_marker(version, description):
    """Best effort New Relic change-tracking marker. Never blocks remediation."""
    if not os.environ.get("NEW_RELIC_API_KEY"):
        return {"skipped": True, "reason": "NEW_RELIC_API_KEY not set"}
    try:
        data = nerdgraph(
            """mutation($guid: EntityGuid!, $version: String!, $description: String!) {
                 changeTrackingCreateDeployment(deployment: {
                   entityGuid: $guid, version: $version, description: $description,
                   deploymentType: BASIC, user: "workflow-automation"
                 }) { deploymentId }
               }""",
            {"guid": entity_guid(), "version": version, "description": description})
        return {"skipped": False, "deployment_id": data["changeTrackingCreateDeployment"]["deploymentId"]}
    except Exception as e:
        log_event(event="marker_failed", error=str(e))
        return {"skipped": True, "reason": str(e)[:200]}


def wait_for(version, timeout=HEALTH_TIMEOUT):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if get_version() == version:
            return True
        time.sleep(1)
    return False


def switch(target, action, reason="", triggered_by=""):
    """Move shop-api to `target`. Idempotent: already there returns noop=True."""
    request_id = uuid.uuid4().hex[:12]
    with _lock:
        before = get_version()
        payload = {"action": action, "request_id": request_id, "version_before": before,
                   "reason": reason, "triggered_by": triggered_by}
        if before == target:
            payload.update(status="ok", version_after=before, verified=True, noop=True,
                           nr_marker={"skipped": True, "reason": "already on target"})
        else:
            try:
                compose_up(target)
                ok = wait_for(target)
                after = get_version()
                marker = fire_marker(target, f"{action}: {before} -> {target}") if ok else \
                    {"skipped": True, "reason": "release did not become healthy"}
                payload.update(status="ok" if ok else "failed", version_after=after,
                               verified=bool(ok and after == target), noop=False, nr_marker=marker)
            except Exception as e:
                payload.update(status="error", version_after=get_version(), verified=False,
                               noop=False, nr_marker={"skipped": True, "reason": "action failed"},
                               error=str(getattr(e, "stderr", None) or e)[:300])
        _history.append({"ts": datetime.now(timezone.utc).isoformat(), **payload})
        del _history[:-20]
        save_history()
    log_event(event="action", **payload)
    return payload


def authorized():
    secret = token()
    if not secret:
        return False
    return hmac.compare_digest(request.headers.get("X-Rollback-Token", ""), secret)


def guarded(handler):
    def wrapper(*args, **kwargs):
        if not token():
            return jsonify({"error": "controller_not_configured"}), 503
        if not authorized():
            log_event(event="unauthorized", path=request.path)
            return jsonify({"error": "unauthorized"}), 401
        return handler(*args, **kwargs)
    wrapper.__name__ = handler.__name__
    return wrapper


def body():
    return request.get_json(silent=True) or {}


# ---- routes ----------------------------------------------------------------

@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/status")
def status():
    return jsonify({"version": get_version(), "service": SERVICE, "history": _history[-10:]})


@app.route("/deploy", methods=["POST"])
@guarded
def deploy():
    version = body().get("version", "v2")
    if version not in ALLOWED_VERSIONS:
        return jsonify({"error": "version_not_allowed", "allowed": list(ALLOWED_VERSIONS)}), 400
    return jsonify(switch(version, "deploy", body().get("reason", ""), body().get("triggered_by", "")))


@app.route("/rollback", methods=["POST"])
@guarded
def rollback():
    return jsonify(switch("v1", "rollback", body().get("reason", "unknown"),
                          body().get("triggered_by", "unknown")))


@app.route("/reset", methods=["POST"])
@guarded
def reset():
    result = switch("v1", "reset", "reset to baseline", body().get("triggered_by", "reset"))
    result["cache_flushed"] = flush_cache()
    return jsonify(result)


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>controller</title>
<style>
 body{font-family:system-ui,sans-serif;margin:2rem auto;max-width:56rem;background:#0b1220;color:#e6edf3}
 .badge{font-size:2.5rem;font-weight:700;padding:.1em .5em;border-radius:10px;display:inline-block;background:#444}
 .v1{background:#1f6f43}.v2{background:#a12a2a}
 table{border-collapse:collapse;width:100%;margin-top:1rem}
 td,th{border-bottom:1px solid #223;padding:.4rem;text-align:left;font-size:.9rem}
 small{color:#8b98a9}
</style></head>
<body>
 <h2>Controller</h2>
 <div>shop-api is running <span id="v" class="badge">...</span></div>
 <p><small>Updates every 3 seconds. Actions need the X-Rollback-Token header.</small></p>
 <table><thead><tr><th>Time (UTC)</th><th>Action</th><th>From</th><th>To</th><th>Verified</th><th>By</th></tr></thead>
 <tbody id="rows"></tbody></table>
<script>
 async function tick(){try{const j=await (await fetch('status')).json();
  const v=document.getElementById('v');v.textContent=j.version||'down';v.className='badge '+(j.version||'');
  document.getElementById('rows').innerHTML=j.history.slice().reverse().map(h=>
   `<tr><td>${h.ts.slice(11,19)}</td><td>${h.action}</td><td>${h.version_before||'-'}</td><td>${h.version_after||'-'}</td><td>${h.verified}${h.noop?' (noop)':''}</td><td>${h.triggered_by||''}</td></tr>`).join('');
 }catch(e){}}
 tick();setInterval(tick,3000);
</script></body></html>"""


@app.route("/")
def index():
    return render_template_string(PAGE)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
