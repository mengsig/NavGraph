// Shared domain primitives used across the client and UI layers.
// These are intentionally tiny type-level declarations that many
// modules depend on.

/** A numeric identifier for any persisted entity. */
export type Id = number;

/** Anything that carries a human-readable name. */
export interface Named {
  name: string;
}

/** Access level a user account can hold. */
export enum Role {
  Admin,
  User,
}
