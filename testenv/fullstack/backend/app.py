"""Flask order service.

Exposes a small CRUD API under the ``/api`` prefix via a Blueprint, plus a
bare ``/health`` probe on the app itself. Handlers delegate all storage work
to the ``store`` module.
"""

from flask import Flask, Blueprint, jsonify, request

from store import (
    all_orders,
    add_order,
    find_order,
    update_order_record,
    remove_order,
)

app = Flask(__name__)
bp = Blueprint("api", __name__, url_prefix="/api")


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


app.register_blueprint(bp)


@app.get("/health")
def health():
    """Liveness probe."""
    return jsonify(status="ok")
