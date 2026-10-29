"""Steady traffic against shop-api so error rate and latency produce alertable data.

Each request runs inside a New Relic background transaction, so this container shows up as
its own APM application and its calls to shop-api appear as linked distributed traces.
"""
import os
import random
import threading
import time

import requests

try:
    import newrelic.agent as nr_agent
except ImportError:  # local runs without the agent installed
    nr_agent = None

BASE = os.environ.get("TARGET_URL", "http://shop-api:5000")
INTERVAL = float(os.environ.get("INTERVAL", "0.1"))
# Parallel workers. A failing v2 request stalls 3 to 5 seconds, so a single sequential loop
# would send almost no traffic exactly when the error condition needs volume.
WORKERS = int(os.environ.get("WORKERS", "6"))
ENDPOINTS = ["/api/orders", "/api/inventory", "/api/users", "/api/checkout",
             "/api/data", "/api/products"]


def traced(fn):
    if nr_agent is None:
        return fn
    return nr_agent.background_task(name="loadgen/request", group="Task")(fn)


@traced
def hit(path):
    if nr_agent is not None:
        nr_agent.add_custom_attribute("loadgen.endpoint", path)
    try:
        return requests.get(BASE + path, timeout=8).status_code
    except requests.RequestException:
        return 0


_lock = threading.Lock()
_sent = _errors = 0


def worker():
    global _sent, _errors
    while True:
        status = hit(random.choice(ENDPOINTS))
        bad = status == 0 or status >= 500
        with _lock:
            _sent += 1
            _errors += bad
            if _sent % 100 == 0:
                print(f"sent={_sent} errors={_errors}", flush=True)
        time.sleep(random.uniform(0, INTERVAL * 2))


def main():
    for _ in range(WORKERS - 1):
        threading.Thread(target=worker, daemon=True).start()
    worker()


if __name__ == "__main__":
    main()
