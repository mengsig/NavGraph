"""Flask order/customer/inventory service.

Exposes CRUD APIs under three blueprints, each with its own ``url_prefix``:
``/api`` (orders), ``/api/customers`` and ``/api/inventory``. A bare ``/health``
probe and a ``/version`` endpoint live directly on the app. Handlers delegate
all storage work to the ``store`` module and fire bus events via ``events``.
"""

from flask import Flask, Blueprint, jsonify, request

from store import (
    all_orders,
    add_order,
    find_order,
    update_order_record,
    remove_order,
    all_customers,
    add_customer,
    find_customer,
    replace_customer_record,
    patch_customer_record,
    remove_customer,
    all_inventory,
    restock_item,
    find_item,
    set_item,
    adjust_item,
    remove_item,
)
from events import announce_shipment, restock_alert, announce_low_stock

app = Flask(__name__)
bp = Blueprint("api", __name__, url_prefix="/api")
customers_bp = Blueprint("customers", __name__, url_prefix="/api/customers")
inventory_bp = Blueprint("inventory", __name__, url_prefix="/api/inventory")


# --- orders (url_prefix="/api") -----------------------------------------


@bp.get("/orders")
def list_orders():
    """List all orders."""
    return jsonify(all_orders())


@bp.post("/orders")
def create_order():
    """Create a new order from the posted JSON body."""
    data = request.get_json()
    order = add_order(data)
    return jsonify(order), 201


@bp.get("/orders/<int:id>")
def get_order(id):
    """Fetch a single order by id."""
    order = find_order(id)
    if order is None:
        return jsonify(error="not found"), 404
    return jsonify(order)


@bp.put("/orders/<int:id>")
def update_order(id):
    """Replace the fields of an existing order."""
    data = request.get_json()
    order = update_order_record(id, data)
    if order is None:
        return jsonify(error="not found"), 404
    return jsonify(order)


@bp.delete("/orders/<int:id>")
def delete_order(id):
    """Delete an order by id."""
    remove_order(id)
    return "", 204


@bp.post("/orders/<int:id>/ship")
def ship_order(id):
    """Mark an order shipped and emit an ``order_shipped`` event."""
    order = update_order_record(id, {"status": "shipped"})
    if order is None:
        return jsonify(error="not found"), 404
    announce_shipment(id)
    return jsonify(order)


# --- customers (url_prefix="/api/customers") ----------------------------


@customers_bp.get("/")
def list_customers():
    """List all customers."""
    return jsonify(all_customers())


@customers_bp.post("/")
def create_customer():
    """Create a new customer from the posted JSON body."""
    data = request.get_json()
    customer = add_customer(data)
    return jsonify(customer), 201


@customers_bp.get("/<int:id>")
def get_customer(id):
    """Fetch a single customer by id."""
    customer = find_customer(id)
    if customer is None:
        return jsonify(error="not found"), 404
    return jsonify(customer)


@customers_bp.put("/<int:id>")
def replace_customer(id):
    """Replace every field of an existing customer."""
    data = request.get_json()
    customer = replace_customer_record(id, data)
    if customer is None:
        return jsonify(error="not found"), 404
    return jsonify(customer)


@customers_bp.patch("/<int:id>")
def patch_customer(id):
    """Partially update an existing customer."""
    data = request.get_json()
    customer = patch_customer_record(id, data)
    if customer is None:
        return jsonify(error="not found"), 404
    return jsonify(customer)


@customers_bp.delete("/<int:id>")
def delete_customer(id):
    """Delete a customer by id."""
    remove_customer(id)
    return "", 204


# --- inventory (url_prefix="/api/inventory") ----------------------------


@inventory_bp.get("/")
def list_inventory():
    """List every stocked item."""
    return jsonify(all_inventory())


@inventory_bp.post("/")
def create_item():
    """Add or top up a stocked item, then re-check low-stock alerts."""
    data = request.get_json()
    item = restock_item(data)
    announce_low_stock()
    return jsonify(item), 201


@inventory_bp.get("/<string:sku>")
def get_item(sku):
    """Fetch a single item by SKU."""
    item = find_item(sku)
    if item is None:
        return jsonify(error="not found"), 404
    return jsonify(item)


@inventory_bp.put("/<string:sku>")
def set_item_route(sku):
    """Overwrite an item's fields wholesale."""
    data = request.get_json()
    item = set_item(sku, data)
    if item is None:
        return jsonify(error="not found"), 404
    return jsonify(item)


@inventory_bp.patch("/<string:sku>")
def adjust_item_route(sku):
    """Apply a signed quantity delta and fire a low-stock alert if needed."""
    data = request.get_json()
    item = adjust_item(sku, data["delta"])
    if item is None:
        return jsonify(error="not found"), 404
    restock_alert(sku)
    return jsonify(item)


@inventory_bp.delete("/<string:sku>")
def delete_item(sku):
    """Remove an item from inventory by SKU."""
    remove_item(sku)
    return "", 204


app.register_blueprint(bp)
app.register_blueprint(customers_bp)
app.register_blueprint(inventory_bp)


@app.get("/health")
def health():
    """Liveness probe."""
    return jsonify(status="ok")


@app.route("/version")
def version():
    """Report the running API version."""
    return jsonify(version="2.0.0")
