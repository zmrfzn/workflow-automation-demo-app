"""Steady traffic against shop-api so error rate and latency produce alertable data.

Each request runs inside a New Relic background transaction, so this container shows up as
its own APM application and its calls to shop-api appear as linked distributed traces.
"""
import os
import random
import time

import requests

try:
    import newrelic.agent as nr_agent
except ImportError:  # local runs without the agent installed
    nr_agent = None

BASE = os.environ.get("TARGET_URL", "http://shop-api:5000")
INTERVAL = float(os.environ.get("INTERVAL", "0.5"))
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


def main():
    sent = errors = 0
    while True:
        status = hit(random.choice(ENDPOINTS))
        sent += 1
        errors += status == 0 or status >= 500
        if sent % 50 == 0:
            print(f"sent={sent} errors={errors}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
