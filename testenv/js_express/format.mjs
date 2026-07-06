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
