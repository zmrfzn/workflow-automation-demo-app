"""shop-api: the sample service for the Workflow Automation masterclass.

The same source builds two images, v1 and v2 (build arg RELEASE). v1 is the healthy
release. v2 is the "bad deploy": its handlers contain real code bugs, a slow path and
a cache bypass (see releases/v2.py). Rolling back means running the v1 image again.
"""
import logging
import os
import time

import redis
from flask import Flask, jsonify, render_template_string

try:
    import newrelic.agent as nr_agent
except ImportError:  # local runs without the agent installed
    nr_agent = None

RELEASE = os.environ.get("APP_RELEASE", "v1")
APP_NAME = os.environ.get("NEW_RELIC_APP_NAME", "workflow-automation-app")

if RELEASE == "v2":
    from releases import v2 as release
else:
    from releases import v1 as release

app = Flask(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s release=" + RELEASE + " %(message)s",
)

cache = redis.Redis(
    host=os.environ.get("REDIS_HOST", "redis"),
    port=int(os.environ.get("REDIS_PORT", "6379")),
    socket_timeout=0.5,
    socket_connect_timeout=0.5,
)
STARTED = time.time()


def _attr(key, value):
    if nr_agent is not None:
        nr_agent.add_custom_attribute(key, value)


@app.before_request
def tag_release():
    _attr("app.release", RELEASE)


@app.route("/health")
def health():
    return jsonify({"status": "ok", "version": RELEASE})


@app.route("/api/status")
def status():
    try:
        cache.ping()
        redis_ok = True
    except Exception:
        redis_ok = False
    return jsonify({
        "app": APP_NAME,
        "version": RELEASE,
        "redis": redis_ok,
        "uptime_seconds": int(time.time() - STARTED),
    })


@app.route("/api/orders")
def orders():
    return jsonify(release.orders())


@app.route("/api/inventory")
def inventory():
    return jsonify(release.inventory())


@app.route("/api/users")
def users():
    return jsonify(release.users())


@app.route("/api/checkout")
def checkout():
    return jsonify(release.checkout())


@app.route("/api/data")
def data():
    return jsonify(release.data())


@app.route("/api/products")
def products():
    body, cache_hit = release.products(cache)
    _attr("app.cache_hit", cache_hit)
    return jsonify(body)


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>shop-api</title>
<style>
 body{font-family:system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#0b1220;color:#e6edf3}
 .card{text-align:center;padding:2rem 3rem;border-radius:12px;background:#111a2e}
 .badge{font-size:4rem;font-weight:700;padding:.2em .6em;border-radius:12px;display:inline-block}
 .v1{background:#1f6f43}.v2{background:#a12a2a}
 small{color:#8b98a9}
</style></head>
<body><div class="card">
 <div>shop-api</div>
 <div id="v" class="badge {{ release }}">{{ release }}</div>
 <p><small>Running release. Reloads every 3 seconds.</small></p>
 <p><small>Endpoints: /api/orders /api/inventory /api/users /api/checkout /api/data /api/products</small></p>
</div>
<script>
 setInterval(async()=>{try{const r=await fetch('/api/status');const j=await r.json();
  const v=document.getElementById('v');v.textContent=j.version;v.className='badge '+j.version;}catch(e){}},3000);
</script></body></html>"""


@app.route("/")
def index():
    return render_template_string(PAGE, release=RELEASE)


@app.errorhandler(Exception)
def handle_exception(e):
    logging.error("Unhandled %s: %s", type(e).__name__, e)
    if nr_agent is not None:
        nr_agent.notice_error()
    return jsonify({"error": type(e).__name__, "message": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
