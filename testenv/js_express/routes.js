// Catalog routes: list, create, update, and delete items. Exported as an
// Express Router that server.js mounts onto the application. Exercises every
// common HTTP verb with a mix of named handlers and inline arrow handlers, and
// publishes change events onto the shared message bus.
const express = require('express');
const db = require('./db');
const { bus } = require('./bus');
const { validateItem, parseId } = require('./validation');

const router = express.Router();

// Authoritative id-keyed store used by the update/patch routes.
const store = new db.CatalogStore();

// GET /items — list every catalog item.
router.get('/items', listItems);

// HEAD /items — cheap existence/count probe via a named handler.
router.head('/items', headItems);

// POST /items — create a new catalog item.
router.post('/items', createItems);

// PUT /items/:id — replace an existing item wholesale.
router.put('/items/:id', replaceItem);

// PATCH /items/:id — merge a partial update via an inline arrow handler.
router.patch('/items/:id', (req, res) => {
  const id = parseId(req.params.id);
  const updated = store.patch(id, req.body);
  if (!updated) {
    res.status(404).json({ error: 'not found' });
    return;
  }
  res.json(updated);
});

// DELETE /items/:id — remove an item by id via an inline arrow handler and
// announce the deletion on the bus.
router.delete('/items/:id', (req, res) => {
  const id = parseId(req.params.id);
  store.remove(id);
  bus.emit('item.deleted', { id });
  res.status(204).end();
});

// Return all stored items as a JSON payload.
function listItems(req, res) {
  const data = db.all();
  res.json(data);
}

// Respond to a HEAD probe with just the item count in a header.
function headItems(req, res) {
  res.set('X-Item-Count', String(db.all().length));
  res.status(200).end();
}

// Persist a new item taken from the request body and announce it.
function createItems(req, res) {
  const problem = validateItem(req.body);
  if (problem) {
    res.status(400).json({ error: problem });
    return;
  }
  const saved = db.insert(req.body);
  bus.emit('item.created', saved);
  res.status(201).json(saved);
}

// Replace an item identified by :id, or 404 if it does not exist.
function replaceItem(req, res) {
  const id = parseId(req.params.id);
  const problem = validateItem(req.body);
  if (problem) {
    res.status(400).json({ error: problem });
    return;
  }
  const updated = store.replace(id, req.body);
  if (!updated) {
    res.status(404).json({ error: 'not found' });
    return;
  }
  res.json(updated);
}

module.exports = router;
