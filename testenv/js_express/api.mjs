// Public barrel for the browser-side catalog API. Re-exports the formatting
// helpers, the functional client, and the class-based client from one place so
// consumers can `import { CatalogClient, loadItems } from './api.mjs'`.
// Exercises `export ... from` re-exports.
export { formatItem, formatStatus } from './format.mjs';
export { loadItems, createItem, replaceItem, removeItem, loadStats } from './client.mjs';
export { CatalogClient } from './apiClient.mjs';

// A convenience default client bound to the /api prefix, built on the
// re-exported class above.
import { CatalogClient } from './apiClient.mjs';
export const defaultClient = new CatalogClient('/api');
