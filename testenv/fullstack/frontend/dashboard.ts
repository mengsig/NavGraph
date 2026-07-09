// Top-level orchestrator: loads data from every API client and wires the
// message bus. Exercises cross-file calls so `callers`/`path` have signal.

import { Order, Customer, InventoryItem, NewOrder } from "./types";
import { listOrders, createOrder, getOrder, updateOrder, deleteOrder, checkHealth } from "./orders";
import { listCustomers, createCustomer, patchCustomer, deleteCustomer } from "./customers";
import { listInventory, restockItem, adjustItem, removeItem } from "./inventory";
import { placeOrder, subscribe } from "./bus";

// Pull a snapshot of everything the dashboard renders.
export async function loadSnapshot(): Promise<{
  orders: Order[];
  customers: Customer[];
  inventory: InventoryItem[];
  healthy: boolean;
}> {
  const orders = await listOrders();
  const customers = await listCustomers();
  const inventory = await listInventory();
  const healthy = await checkHealth();
  return { orders, customers, inventory, healthy };
}

// Create an order both over HTTP and via the event bus.
export async function submitOrder(order: NewOrder): Promise<Order> {
  const created = await createOrder(order);
  placeOrder(order);
  return created;
}

// Drive a few mutations to exercise the write endpoints.
export async function seedDemo(): Promise<void> {
  const c = await createCustomer({ name: "Ada", email: "ada@example.com" });
  await patchCustomer(c.id, { tier: "gold" });
  await restockItem({ sku: "ABC-1", name: "Widget", on_hand: 3 });
  await adjustItem("ABC-1", 10);
  const order = await createOrder({ sku: "ABC-1", quantity: 2 });
  await updateOrder(order.id, { sku: "ABC-1", quantity: 5 });
  await getOrder(order.id);
  await deleteOrder(order.id);
  await removeItem("ABC-1");
  await deleteCustomer(c.id);
}

// Start listening for backend-emitted events.
export function start(): void {
  subscribe();
}
