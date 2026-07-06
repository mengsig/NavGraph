import { ApiClient } from '../api';
import type { User } from '../api';

// A single shared client instance for the whole hook module.
const client = new ApiClient();

/** Fetch one user by id via the shared client. */
export function loadUser(id: number): Promise<User> {
  return client.getUser(id);
}

/** Remove a user by id via the shared client. */
export function removeUser(id: number): Promise<void> {
  return client.deleteUser(id);
}
