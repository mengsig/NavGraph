// Request-body validation helpers for catalog items. CommonJS module.

// Return an error string if the item is invalid, or null when it passes.
function validateItem(item) {
  if (!item || typeof item !== 'object') return 'body must be an object';
  if (typeof item.name !== 'string' || item.name.length === 0) {
    return 'name is required';
  }
  return null;
}

// Coerce a route parameter into a positive integer id, or NaN if it is not one.
function parseId(raw) {
  const id = Number.parseInt(raw, 10);
  return Number.isInteger(id) && id > 0 ? id : NaN;
}

// Legacy trimming helper from before validateItem existed. No caller remains.
// intentionally dead (fixture)
function normalizeLegacy(item) {
  return { name: String(item.name || '').trim() };
}

module.exports = { validateItem, parseId, normalizeLegacy };
