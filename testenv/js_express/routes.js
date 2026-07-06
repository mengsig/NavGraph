// Catalog routes: list, create, and delete items. Exported as an Express
// Router that server.js mounts onto the application.
const express = require('express');
const db = require('./db');

const router = express.Router();

// GET /items — list every catalog item.
router.get('/items', listItems);

// POST /items — create a new catalog item.
router.post('/items', createItems);

// DELETE /items/:id — remove an item by id via an inline arrow handler.
router.delete('/items/:id', (req, res) => {
  res.status(204).end();
});

// Return all stored items as a JSON payload.
function listItems(req, res) {
  const data = db.all();
  res.json(data);
}

// Persist a new item taken from the request body.
function createItems(req, res) {
  const saved = db.insert(req.body);
  res.status(201).json(saved);
}

module.exports = router;
