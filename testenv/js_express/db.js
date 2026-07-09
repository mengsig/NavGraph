// In-memory catalog storage. No external database — this is a demo store
// backed by a plain array so the routes have something to read and write.
// CommonJS module (require / module.exports).
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
// intentionally dead (fixture)
function count() {
  return all().length;
}

// A richer store used by the admin routes. Wraps the same backing array in a
// class so method edges (constructor + instance methods) are exercised.
class CatalogStore {
  // Seed the store from an optional list of initial items.
  constructor(seed = []) {
    this.rows = seed.slice();
    this.nextId = this.rows.length + 1;
  }

  // Return every row as a fresh array.
  list() {
    return this.rows.slice();
  }

  // Look up a single row by its numeric id, or undefined.
  findById(id) {
    return this.rows.find((row) => row.id === id);
  }

  // Insert a new row, assigning an auto-incrementing id.
  add(item) {
    const row = Object.assign({ id: this.nextId }, item);
    this.nextId += 1;
    this.rows.push(row);
    return row;
  }

  // Replace an existing row wholesale; returns the updated row or null.
  replace(id, item) {
    const existing = this.findById(id);
    if (!existing) return null;
    Object.assign(existing, item, { id });
    return existing;
  }

  // Merge a partial patch into an existing row; returns it or null.
  patch(id, changes) {
    const existing = this.findById(id);
    if (!existing) return null;
    Object.assign(existing, changes);
    return existing;
  }

  // Remove a row by id and report whether anything was deleted.
  remove(id) {
    const before = this.rows.length;
    this.rows = this.rows.filter((row) => row.id !== id);
    return this.rows.length < before;
  }

  // Number of rows currently held.
  size() {
    return this.rows.length;
  }
}

// A superseded store kept only so the migration notes make sense. Nothing
// constructs it any more.
// intentionally dead (fixture)
class LegacyStore {
  constructor() {
    this.data = {};
  }

  put(key, value) {
    this.data[key] = value;
  }
}

module.exports = { all, insert, count, CatalogStore, LegacyStore };
