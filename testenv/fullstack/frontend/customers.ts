// Typed client for the backend customer API (Blueprint url_prefix
// "/api/customers"). Collection endpoints use `fetch`; per-id endpoints use
// `axios`, mirroring how a real app mixes HTTP libraries.

import axios from "axios";
import { Customer, NewCustomer } from "./types";

// GET /api/customers -> list_customers
export async function listCustomers(): Promise<Customer[]> {
  const res = await fetch("/api/customers");
  return res.json();
}

// POST /api/customers -> create_customer
export async function createCustomer(c: NewCustomer): Promise<Customer> {
  const res = await fetch("/api/customers", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(c),
  });
  return res.json();
}

// GET /api/customers/:id -> get_customer
export async function getCustomer(id: number): Promise<Customer> {
  const res = await axios.get(`/api/customers/${id}`);
  return res.data;
}

// PUT /api/customers/:id -> replace_customer
export async function replaceCustomer(id: number, c: NewCustomer): Promise<Customer> {
  const res = await axios.put(`/api/customers/${id}`, c);
  return res.data;
}

// PATCH /api/customers/:id -> patch_customer
export async function patchCustomer(id: number, fields: Partial<NewCustomer>): Promise<Customer> {
  const res = await axios.patch(`/api/customers/${id}`, fields);
  return res.data;
}

// DELETE /api/customers/:id -> delete_customer
export async function deleteCustomer(id: number): Promise<void> {
  await axios.delete(`/api/customers/${id}`);
}
