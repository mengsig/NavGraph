// Typed client for the backend inventory API (Blueprint url_prefix
// "/api/inventory"). SKUs are string path params, exercising a non-numeric
// route parameter.

import axios from "axios";
import { InventoryItem, NewItem } from "./types";

// GET /api/inventory -> list_inventory
export async function listInventory(): Promise<InventoryItem[]> {
  const res = await fetch("/api/inventory");
  return res.json();
}

// POST /api/inventory -> create_item
export async function restockItem(item: NewItem): Promise<InventoryItem> {
  const res = await fetch("/api/inventory", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(item),
  });
  return res.json();
}

// GET /api/inventory/:sku -> get_item
export async function getItem(sku: string): Promise<InventoryItem> {
  const res = await axios.get(`/api/inventory/${sku}`);
  return res.data;
}

// PUT /api/inventory/:sku -> set_item_route
export async function setItem(sku: string, item: NewItem): Promise<InventoryItem> {
  const res = await axios.put(`/api/inventory/${sku}`, item);
  return res.data;
}

// PATCH /api/inventory/:sku -> adjust_item_route
export async function adjustItem(sku: string, delta: number): Promise<InventoryItem> {
  const res = await axios.patch(`/api/inventory/${sku}`, { delta });
  return res.data;
}

// DELETE /api/inventory/:sku -> delete_item
export async function removeItem(sku: string): Promise<void> {
  await axios.delete(`/api/inventory/${sku}`);
}
