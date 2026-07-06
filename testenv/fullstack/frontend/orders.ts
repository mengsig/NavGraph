// Typed client for the backend order API. Uses `fetch` for the collection
// endpoints and `axios` for the per-id endpoints, mirroring how a real app
// often mixes HTTP libraries.

import axios from "axios";
import { Order, NewOrder } from "./types";

// GET /api/orders -> list_orders
export async function listOrders(): Promise<Order[]> {
  const res = await fetch("/api/orders");
  return res.json();
}

// POST /api/orders -> create_order
export async function createOrder(o: NewOrder): Promise<Order> {
  const res = await fetch("/api/orders", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(o),
  });
  return res.json();
}

// GET /api/orders/:id -> get_order
export async function getOrder(id: number): Promise<Order> {
  const res = await axios.get(`/api/orders/${id}`);
  return res.data;
}

// PUT /api/orders/:id -> update_order
export async function updateOrder(id: number, o: NewOrder): Promise<Order> {
  const res = await axios.put(`/api/orders/${id}`, o);
  return res.data;
}

// DELETE /api/orders/:id -> delete_order
export async function deleteOrder(id: number): Promise<void> {
  await axios.delete(`/api/orders/${id}`);
}

// GET /health -> health
export async function checkHealth(): Promise<boolean> {
  const res = await fetch("/health");
  return res.ok;
}

// Deliberately hits an endpoint the backend does not serve: must link to
// nothing.
export async function bogus(): Promise<void> {
  await fetch("/api/nonexistent");
}
