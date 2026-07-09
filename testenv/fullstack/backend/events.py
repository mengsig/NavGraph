"""Backend event wiring: subscribe to keys the client emits, and emit keys the
client subscribes to.

Import this module for its side effect of registering handlers on the bus.
"""

import bus
from store import add_order, find_item, low_stock


def on_order_placed(payload):
    """Handle an ``order_placed`` event coming from the client."""
    order = add_order(payload)
    return order


# The client fires "order_placed"; we handle it here.
bus.on("order_placed", on_order_placed)


def announce_low_stock():
    """Emit an ``inventory_low`` event for each item below its reorder point."""
    for item in low_stock():
        bus.emit("inventory_low", item)


def announce_shipment(order_id):
    """Emit an ``order_shipped`` event the client listens for."""
    payload = {"order_id": order_id}
    bus.emit("order_shipped", payload)


def restock_alert(sku):
    """Emit ``inventory_low`` for a single SKU that just dropped."""
    item = find_item(sku)
    if item is not None:
        bus.emit("inventory_low", item)
