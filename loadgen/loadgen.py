"""Steady traffic against shop-api so error rate and latency produce alertable data."""
import os
import random
import time

import requests

BASE = os.environ.get("TARGET_URL", "http://shop-api:5000")
INTERVAL = float(os.environ.get("INTERVAL", "0.5"))
ENDPOINTS = ["/api/orders", "/api/inventory", "/api/users", "/api/checkout",
             "/api/data", "/api/products"]


def main():
    sent = errors = 0
    while True:
        path = random.choice(ENDPOINTS)
        try:
            status = requests.get(BASE + path, timeout=8).status_code
        except requests.RequestException:
            status = 0
        sent += 1
        errors += status == 0 or status >= 500
        if sent % 50 == 0:
            print(f"sent={sent} errors={errors}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
