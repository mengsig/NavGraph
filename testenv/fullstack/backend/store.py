"""In-memory order storage backing the HTTP handlers.

A tiny stand-in for a real repository/DB layer so the route handlers have
something concrete to call. All state lives in module-level dicts.
"""

_orders = {}
_counter = {"next": 1}


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
