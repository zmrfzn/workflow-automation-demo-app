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


def delay_range(name, default):
    """Read a "min-max" seconds range such as "2-5" from the environment."""
    raw = os.environ.get(name, default)
    try:
        lo, hi = (float(x) for x in raw.split("-", 1))
    except ValueError:
        lo, hi = (float(x) for x in default.split("-", 1))
    return min(lo, hi), max(lo, hi)


# Pause after each request, per worker. The error scenario (v2) sends a little faster so the
# error rate builds up while the alert is waited for; normal traffic (v1) stays light.
DELAY_NORMAL = delay_range("DELAY_NORMAL", "2-5")
DELAY_ERROR = delay_range("DELAY_ERROR", "0.8-2")
# Parallel workers. A failing v2 request stalls 3 to 5 seconds, so a single sequential loop
# would send almost no traffic exactly when the error condition needs volume.
WORKERS = int(os.environ.get("WORKERS", "6"))
HEARTBEAT = float(os.environ.get("HEARTBEAT", "10"))
RELEASE_POLL = float(os.environ.get("RELEASE_POLL", "10"))
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
_release = None  # last version shop-api reported; None until known or while it is down


def log(msg):
    print(f"loadgen {msg}", flush=True)


def fmt(rng):
    return f"{rng[0]:g}-{rng[1]:g}s"


def current_delay():
    return DELAY_ERROR if _release == "v2" else DELAY_NORMAL


def poll_release():
    """Ask shop-api which release it runs, the same /api/status the controller reads."""
    global _release
    try:
        version = requests.get(BASE + "/api/status", timeout=3).json().get("version")
    except (requests.RequestException, ValueError):
        version = None
    if version != _release:
        before = fmt(current_delay())
        _release = version
        log(f"release is now {version or 'unknown'}: delay {before} -> {fmt(current_delay())}")


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
        time.sleep(random.uniform(*current_delay()))


def heartbeat(alive):
    """One line per interval, so a quiet log always means a stopped process, never slow traffic."""
    global _window_sent, _window_errors
    with _lock:
        sent, errors, _window_sent, _window_errors = _window_sent, _window_errors, 0, 0
    pct = round(100 * errors / sent) if sent else 0
    log(f"workers={alive}/{WORKERS} release={_release or 'unknown'} delay={fmt(current_delay())} "
        f"rps={sent / HEARTBEAT:.1f} errors={pct}% window={HEARTBEAT:g}s total={_total}")


def on_sigterm(signum, _frame):
    # Python is PID 1 here, so without a handler `docker stop` waits 10 s and kills without a trace.
    log(f"stopping: {signal.Signals(signum).name} received")
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, on_sigterm)
    log(f"starting: target={BASE} workers={WORKERS} "
        f"delay normal={fmt(DELAY_NORMAL)} error(v2)={fmt(DELAY_ERROR)}")
    poll_release()
    threads = []
    next_beat = time.time() + HEARTBEAT
    next_poll = time.time() + RELEASE_POLL
    while True:
        dead = sum(1 for t in threads if not t.is_alive())
        if dead:
            log(f"respawning {dead} dead worker(s)")
        threads = [t for t in threads if t.is_alive()]
        while len(threads) < WORKERS:
            t = threading.Thread(target=worker, daemon=True)
            t.start()
            threads.append(t)
        if time.time() >= next_poll:
            poll_release()
            next_poll = time.time() + RELEASE_POLL
        if time.time() >= next_beat:
            heartbeat(len(threads))
            next_beat += HEARTBEAT
        time.sleep(1)


if __name__ == "__main__":
    main()
