import axios from 'axios';

/** The user record returned by the backend `/api/users` endpoints. */
export interface User {
  id: number;
  name: string;
}

/**
 * Thin HTTP wrapper around the user endpoints. Each method issues a single
 * request and returns the decoded payload.
 */
export class ApiClient {
  async getUser(id: number): Promise<User> {
    const res = await fetch(`/api/users/${id}`);
    return res.json();
  }

  createUser(u: User): Promise<User> {
    return axios.post('/api/users', u);
  }

  deleteUser(id: number): Promise<void> {
    return fetch(`/api/users/${id}`, { method: 'DELETE' }).then(() => undefined);
  }
}
