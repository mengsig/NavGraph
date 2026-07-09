// Browser-side client for the catalog API. ES module using `import`, `fetch`,
// and axios so the cross-file import edge and the client-call -> route edges
// are both exercised.
import axios from 'axios';
import { formatItem, formatStatus } from './format.mjs';

// Fetch all items from the catalog endpoint and format them for display.
export async function loadItems() {
  const response = await fetch('/items');
  const items = await response.json();
  return items.map(formatItem);
}

// Create a new catalog item via the API and return the formatted result.
export async function createItem(item) {
  const response = await axios.post('/items', item);
  return formatItem(response.data);
}

// Replace an item by id, passing an explicit method + headers to fetch.
export async function replaceItem(id, item) {
  const response = await fetch(`/items/${id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(item),
  });
  return formatItem(await response.json());
}

// Delete an item by id using axios with an explicit method option.
export async function removeItem(id) {
  await axios({ method: 'delete', url: `/items/${id}` });
  return id;
}

// Fetch the admin stats endpoint and render a short status string.
export async function loadStats() {
  const response = await fetch('/admin/stats', {
    headers: { 'x-admin-token': 'let-me-in' },
  });
  const body = await response.json();
  return formatStatus(body.count);
}

// Wire the exported client functions to page buttons on load.
function bindUi() {
  loadItems();
  document.getElementById('add').onclick = () => createItem(readForm());
}

// Read the new-item form fields into a plain object.
function readForm() {
  return { name: 'sample' };
}
