"""In-memory storage backing the HTTP handlers.

A tiny stand-in for a real repository/DB layer so the route handlers have
something concrete to call. All state lives in module-level dicts. Orders are
plain dicts; customers and inventory items are built from the dataclasses in
``models`` and returned as dicts for JSON serialization.
"""

from dataclasses import asdict

from models import Customer, InventoryItem

_orders = {}
_counter = {"next": 1}

_customers = {}
_customer_counter = {"next": 1}

_inventory = {}


def all_orders():
    """Return a list of every stored order."""
    return list(_orders.values())


def add_order(data):
    """Insert a new order, assigning it the next id, and return it."""
    oid = _counter["next"]
    _counter["next"] = oid + 1
    record = {"id": oid}
    record.update(data)
    _orders[oid] = record
    return record


def find_order(oid):
    """Look up a single order by id, or None if it does not exist."""
    return _orders.get(oid)


def update_order_record(oid, data):
    """Merge ``data`` into an existing order and return the updated record."""
    record = find_order(oid)
    if record is not None:
        record.update(data)
    return record


def remove_order(oid):
    """Delete an order by id if it is present."""
    _orders.pop(oid, None)


# --- customers -----------------------------------------------------------


def all_customers():
    """Return every stored customer as a dict."""
    return list(_customers.values())


def add_customer(data):
    """Create a customer from ``data`` and return it as a dict."""
    cid = _customer_counter["next"]
    _customer_counter["next"] = cid + 1
    customer = Customer(id=cid, name=data["name"], email=data["email"],
                        tier=data.get("tier", "standard"))
    record = asdict(customer)
    _customers[cid] = record
    return record


def find_customer(cid):
    """Look up a single customer by id, or None."""
    return _customers.get(cid)


def replace_customer_record(cid, data):
    """Replace every mutable field of an existing customer."""
    record = find_customer(cid)
    if record is None:
        return None
    record["name"] = data["name"]
    record["email"] = data["email"]
    record["tier"] = data.get("tier", "standard")
    return record


def patch_customer_record(cid, data):
    """Merge only the supplied fields into an existing customer."""
    record = find_customer(cid)
    if record is not None:
        record.update(data)
    return record


def remove_customer(cid):
    """Delete a customer by id if present."""
    _customers.pop(cid, None)


# --- inventory -----------------------------------------------------------


def all_inventory():
    """Return every stocked item as a dict."""
    return list(_inventory.values())


def restock_item(data):
    """Add a new item (or top up an existing one) and return it."""
    item = InventoryItem(sku=data["sku"], name=data["name"],
                         on_hand=data.get("on_hand", 0),
                         reorder_at=data.get("reorder_at", 5))
    record = asdict(item)
    _inventory[item.sku] = record
    return record


def find_item(sku):
    """Look up a single inventory item by SKU, or None."""
    return _inventory.get(sku)


def set_item(sku, data):
    """Overwrite an item's fields wholesale and return it."""
    record = find_item(sku)
    if record is None:
        return None
    record["name"] = data["name"]
    record["on_hand"] = data["on_hand"]
    record["reorder_at"] = data.get("reorder_at", 5)
    return record


def adjust_item(sku, delta):
    """Apply a signed delta to an item's on-hand count and return it."""
    record = find_item(sku)
    if record is None:
        return None
    record["on_hand"] = record["on_hand"] + delta
    return record


def remove_item(sku):
    """Delete an inventory item by SKU if present."""
    _inventory.pop(sku, None)


def low_stock():
    """Return items whose on-hand count has fallen to the reorder point."""
    return [r for r in _inventory.values() if r["on_hand"] <= r["reorder_at"]]


# intentionally dead (fixture): nothing calls this private migration helper.
def _legacy_migrate(records):
    """Rewrite pre-v2 order rows in place. Superseded and never invoked."""
    for record in records:
        record.setdefault("status", "pending")
    return records
