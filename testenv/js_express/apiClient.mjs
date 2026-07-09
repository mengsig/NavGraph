// Object-oriented wrapper around the catalog HTTP API. ES module exposing a
// class with async methods that call fetch/axios with explicit method options,
// so navgraph sees both the class methods and the client -> route edges.
import axios from 'axios';
import { formatItem, formatStatus } from './format.mjs';

// A small client bound to a base URL, e.g. new CatalogClient('/api').
export class CatalogClient {
  // Store the base URL used to build every request path.
  constructor(baseUrl = '') {
    this.baseUrl = baseUrl;
  }

  // Build a full URL for a catalog path.
  url(path) {
    return `${this.baseUrl}${path}`;
  }

  // GET /items — list items and format each for display.
  async list() {
    const response = await fetch(this.url('/items'), { method: 'GET' });
    const items = await response.json();
    return items.map(formatItem);
  }

  // POST /items — create an item via axios with an explicit config object.
  async create(item) {
    const response = await axios.post(this.url('/items'), item, {
      headers: { 'Content-Type': 'application/json' },
    });
    return formatItem(response.data);
  }

  // PATCH /items/:id — merge a partial change into an existing item.
  async patch(id, changes) {
    const response = await fetch(this.url(`/items/${id}`), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(changes),
    });
    return formatItem(await response.json());
  }

  // GET /admin/stats — read the admin count and render a status string.
  async stats() {
    const response = await axios.get(this.url('/admin/stats'), {
      headers: { 'x-admin-token': 'let-me-in' },
    });
    return formatStatus(response.data.count);
  }
}
