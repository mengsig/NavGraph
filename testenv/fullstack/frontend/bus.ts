// Frontend half of the cross-language message bus. We emit keys the Flask
// backend subscribes to (see backend/events.py) and subscribe to keys the
// backend emits. `socket` is a thin stand-in for a real socket.io client.

import { NewOrder, InventoryItem, OrderEvent } from "./types";

interface Socket {
  emit(event: string, payload: unknown): void;
  on(event: string, handler: (payload: unknown) => void): void;
}

const socket: Socket = {
  emit() {},
  on() {},
};

// Emit "order_placed" -> handled by backend on_order_placed.
export function placeOrder(order: NewOrder): void {
  socket.emit("order_placed", order);
}

// Handle "inventory_low" -> emitted by backend announce_low_stock / restock_alert.
function onInventoryLow(item: InventoryItem): void {
  console.warn(`low stock: ${item.sku} (${item.on_hand} left)`);
}

// Handle "order_shipped" -> emitted by backend announce_shipment.
function onOrderShipped(event: OrderEvent): void {
  console.info(`order ${event.order_id} shipped`);
}

// Wire the backend-emitted events to their frontend handlers.
export function subscribe(): void {
  socket.on("inventory_low", (p) => onInventoryLow(p as InventoryItem));
  socket.on("order_shipped", (p) => onOrderShipped(p as OrderEvent));
}

// intentionally dead (fixture): not exported and never called internally.
function _formatEvent(event: OrderEvent): string {
  return `#${event.order_id}`;
}
