"""Release v2: the bad deploy. Each handler below ships a real bug.

Learners are meant to read this file in the editor, find the bugs, and see them in
APM error traces. Keep the bugs as genuine code defects (not config flags) so that
rolling back to v1 is a real change of what is running.
"""
import random
import time

import requests

PROMO_RATES = {"SAVE10": 0.10, "SAVE20": 0.20, "VIP30": 0.30}
CATALOG = [{"sku": "SKU-4892-BLU", "name": "Blue widget", "price": 29.99},
           {"sku": "SKU-1177-RED", "name": "Red widget", "price": 19.99}]


def _fetch_orders(user_id):
    """Call payment-svc. v2 raised the read timeout and the service now stalls."""
    time.sleep(random.uniform(3.0, 5.0))
    raise requests.exceptions.Timeout(
        "HTTPSConnectionPool(host='payment-svc.internal', port=443): "
        f"Read timed out. (read timeout=5.0) on GET /v2/users/{user_id}/orders")


def orders():
    if random.random() < 0.85:
        _fetch_orders("usr_8f3a9c")
    return {"user_id": "usr_8f3a9c", "orders": [{"id": "ord_001", "total": 59.97}]}


def inventory():
    # catalog-svc renamed 'sku_id' to 'catalog_sku'; this lookup was not updated.
    response = {"catalog_sku": "SKU-4892-BLU", "stock_count": 14}
    if random.random() < 0.80:
        return {"sku": response["sku_id"]}  # KeyError: 'sku_id'
    return {"sku": response["catalog_sku"], "available": True, "stock_count": 14}


def users():
    # user-svc returns None for expired sessions and the caller never checks.
    user = None if random.random() < 0.75 else type("U", (), {"account_id": "acc_7712", "tier": "premium"})
    return {"id": "usr_8f3a9c", "account_id": user.account_id, "tier": user.tier}  # AttributeError


def _apply_promo_discount(subtotal, promo_code):
    # Parameter was renamed promo -> promo_code but this reference was missed.
    if promo:  # noqa: F821  NameError: name 'promo' is not defined
        return subtotal * PROMO_RATES.get(promo, 0.0)  # noqa: F821
    return 0.0


def checkout():
    cart = {"promo_code": "SAVE10", "line_items": [{"price": 29.99, "qty": 2}]}
    subtotal = round(sum(i["price"] * i["qty"] for i in cart["line_items"]), 2)
    tax = round(subtotal * 0.08, 2)
    if random.random() < 0.90:
        discount = _apply_promo_discount(subtotal, cart["promo_code"])
    else:
        discount = 0.0
    return {"subtotal": subtotal, "tax": tax, "discount": discount,
            "total": round(subtotal + tax - discount, 2)}


def data():
    # pricing-svc returns 'N/A' for delisted SKUs after a data migration.
    raw_price = "N/A" if random.random() < 0.70 else "29.99"
    return {"sku": "SKU-4892-BLU", "price": float(raw_price)}  # ValueError


def products(cache):
    """v2 removed the cache lookup, so every request pays the slow lookup."""
    time.sleep(0.6)
    return {"products": CATALOG, "source": "database"}, False
