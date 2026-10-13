"""Release v1: the healthy release. Same endpoints as v2, with the bugs fixed."""
import time

PROMO_RATES = {"SAVE10": 0.10, "SAVE20": 0.20, "VIP30": 0.30}
CATALOG = [{"sku": "SKU-4892-BLU", "name": "Blue widget", "price": 29.99},
           {"sku": "SKU-1177-RED", "name": "Red widget", "price": 19.99}]


def orders():
    return {"user_id": "usr_8f3a9c", "orders": [{"id": "ord_001", "total": 59.97}]}


def inventory():
    response = {"catalog_sku": "SKU-4892-BLU", "stock_count": 14, "warehouse": "US-WEST-2"}
    return {"sku": response["catalog_sku"], "available": response["stock_count"] > 0,
            "stock_count": response["stock_count"]}


def users():
    user = {"account_id": "acc_7712", "tier": "premium"}
    return {"id": "usr_8f3a9c", "account_id": user["account_id"], "tier": user["tier"]}


def _apply_promo_discount(subtotal, promo_code):
    return subtotal * PROMO_RATES.get(promo_code, 0.0)


def checkout():
    cart = {"promo_code": "SAVE10", "line_items": [{"price": 29.99, "qty": 2}]}
    subtotal = round(sum(i["price"] * i["qty"] for i in cart["line_items"]), 2)
    tax = round(subtotal * 0.08, 2)
    discount = round(_apply_promo_discount(subtotal, cart["promo_code"]), 2)
    return {"subtotal": subtotal, "tax": tax, "discount": discount,
            "total": round(subtotal + tax - discount, 2)}


def data():
    return {"sku": "SKU-4892-BLU", "price": float("29.99")}


def products(cache):
    """Read-through cache with a 60 second TTL. Returns (body, cache_hit)."""
    try:
        cached = cache.get("products")
    except Exception:
        cached = None
    if cached:
        return {"products": CATALOG, "source": "cache"}, True
    time.sleep(0.2)  # the slow backing lookup that the cache protects
    try:
        cache.set("products", "1", ex=60)
    except Exception:
        pass
    return {"products": CATALOG, "source": "database"}, False
