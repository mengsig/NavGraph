"""Domain data models shared by the storage layer and handlers.

These dataclasses give the otherwise dict-based store some concrete shapes so
that type usage crosses files (``store`` constructs them, ``events`` reads
them).
"""

from dataclasses import dataclass, field


@dataclass
class Customer:
    """A registered customer account."""

    id: int
    name: str
    email: str
    tier: str = "standard"


@dataclass
class InventoryItem:
    """A stocked SKU and its on-hand quantity."""

    sku: str
    name: str
    on_hand: int
    reorder_at: int = 5


@dataclass
class OrderEvent:
    """An event payload passed across the message bus."""

    kind: str
    order_id: int
    detail: dict = field(default_factory=dict)


# intentionally dead (fixture): no code constructs or imports LegacyShipment.
@dataclass
class LegacyShipment:
    """Old shipment record kept only for a migration that never shipped."""

    tracking: str
    carrier: str
    delivered: bool = False
