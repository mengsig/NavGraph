// Browser-side client for the catalog API. ES module using `import`, `fetch`,
// and axios so the cross-file import edge and the client-call -> route edges
// are both exercised.
import axios from 'axios';
import { formatItem } from './format.mjs';

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

// Wire the exported client functions to page buttons on load.
function bindUi() {
  loadItems();
  document.getElementById('add').onclick = () => createItem(readForm());
}

// Read the new-item form fields into a plain object.
function readForm() {
  return { name: 'sample' };
}
