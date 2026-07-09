import type { Account } from "../models";

/** GET /api/users — list every account. */
export async function fetchAccounts(): Promise<Account[]> {
  const res = await fetch("/api/users", { method: "GET" });
  return res.json();
}

/** PUT /api/users/:id — fully replace an account record. */
export async function replaceAccount(id: number, acc: Account): Promise<Account> {
  const res = await fetch(`/api/users/${id}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(acc),
  });
  return res.json();
}

/** PATCH /api/users/:id — apply a partial change to an account. */
export async function patchAccount(
  id: number,
  changes: Partial<Account>,
): Promise<Account> {
  const res = await fetch(`/api/users/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(changes),
  });
  return res.json();
}
