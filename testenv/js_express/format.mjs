// Formatting helpers for catalog items shown in the UI. ES module.

// Produce a display label for a single item.
export function formatItem(item) {
  return `${item.name} (#${item.id})`;
}

// Join a list of items into a comma-separated summary. Not referenced by the
// client yet — a genuinely uncalled export.
export function summarize(items) {
  return items.map(formatItem).join(', ');
}

// Render a short status line for a request result. Used by the API client.
export function formatStatus(count) {
  return count === 1 ? '1 item' : `${count} items`;
}
