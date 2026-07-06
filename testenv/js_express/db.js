// In-memory catalog storage. No external database — this is a demo store
// backed by a plain array so the routes have something to read and write.
const items = [];

// Return a shallow copy of all stored items.
function all() {
  return items.slice();
}

// Add an item to the store and return the value that was inserted.
function insert(item) {
  items.push(item);
  return item;
}

// Number of items currently held. Kept for parity with a real repository
// but not wired into any route yet — genuinely uncalled.
function count() {
  return all().length;
}

module.exports = { all, insert, count };
