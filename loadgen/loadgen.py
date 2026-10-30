"""Steady traffic against shop-api so error rate and latency produce alertable data.

Each request runs inside a New Relic background transaction, so this container shows up as
its own APM application and its calls to shop-api appear as linked distributed traces.
"""
import os
import random
import signal
import sys
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
HEARTBEAT = float(os.environ.get("HEARTBEAT", "10"))
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
_total = _window_sent = _window_errors = 0


def log(msg):
    print(f"loadgen {msg}", flush=True)


def worker():
    """Never returns: an unexpected error is logged and the loop carries on."""
    global _total, _window_sent, _window_errors
    while True:
        try:
            status = hit(random.choice(ENDPOINTS))
            with _lock:
                _total += 1
                _window_sent += 1
                _window_errors += status == 0 or status >= 500
        except Exception as e:  # noqa: BLE001  a dead thread silently cuts the traffic
            log(f"worker error: {type(e).__name__}: {e}")
            time.sleep(1)
        time.sleep(random.uniform(0, INTERVAL * 2))


def heartbeat(alive):
    """One line per interval, so a quiet log always means a stopped process, never slow traffic."""
    global _window_sent, _window_errors
    with _lock:
        sent, errors, _window_sent, _window_errors = _window_sent, _window_errors, 0, 0
    pct = round(100 * errors / sent) if sent else 0
    log(f"workers={alive}/{WORKERS} rps={sent / HEARTBEAT:.1f} errors={pct}% "
        f"window={HEARTBEAT:g}s total={_total}")


def on_sigterm(signum, _frame):
    # Python is PID 1 here, so without a handler `docker stop` waits 10 s and kills without a trace.
    log(f"stopping: {signal.Signals(signum).name} received")
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, on_sigterm)
    log(f"starting: target={BASE} workers={WORKERS} interval={INTERVAL}s")
    threads = []
    next_beat = time.time() + HEARTBEAT
    while True:
        dead = sum(1 for t in threads if not t.is_alive())
        if dead:
            log(f"respawning {dead} dead worker(s)")
        threads = [t for t in threads if t.is_alive()]
        while len(threads) < WORKERS:
            t = threading.Thread(target=worker, daemon=True)
            t.start()
            threads.append(t)
        if time.time() >= next_beat:
            heartbeat(len(threads))
            next_beat += HEARTBEAT
        time.sleep(1)


if __name__ == "__main__":
    main()
