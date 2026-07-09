import type { Named } from "../types";
import { Role } from "../types";

/** A fully-detailed account record used by the admin views. */
export interface Account extends Named {
  id: number;
  role: Role;
  email: string;
  active: boolean;
}

/**
 * A result wrapper: either a decoded value or a human-readable error. Generic
 * over the success type so every client method can return `Result<T>`.
 */
export type Result<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

/** Build a successful Result. */
export function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

/** Build a failed Result carrying an error message. */
export function fail<T>(error: string): Result<T> {
  return { ok: false, error };
}
