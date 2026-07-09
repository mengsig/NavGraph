// Admin sub-router. server.js mounts this at '/admin', so these paths become
// /admin/stats, /admin/items, etc. Guarded by the requireAdmin middleware.
const express = require('express');
const db = require('./db');
const { requireAdmin } = require('./middleware');

const adminRouter = express.Router();

// Its own store instance so admin stats are independent of the public routes.
const store = new db.CatalogStore([{ id: 1, name: 'seed' }]);

// Every admin route requires the shared-secret header.
adminRouter.use(requireAdmin);

// GET /admin/stats — report how many rows the admin store holds.
adminRouter.get('/stats', statsHandler);

// OPTIONS /admin/stats — advertise the allowed verbs via an inline arrow.
adminRouter.options('/stats', (req, res) => {
  res.set('Allow', 'GET,OPTIONS');
  res.status(204).end();
});

// DELETE /admin/items — purge every row and report how many were removed.
adminRouter.delete('/items', (req, res) => {
  const removed = store.size();
  purgeAll();
  res.json({ removed });
});

// Report the current store size as JSON.
function statsHandler(req, res) {
  res.json({ count: store.size() });
}

// Remove every row from the admin store.
function purgeAll() {
  for (const row of store.list()) {
    store.remove(row.id);
  }
}

module.exports = adminRouter;
