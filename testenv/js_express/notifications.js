// Subscribes to catalog events emitted by the routes and turns them into log
// lines. Uses a *destructured* CommonJS require so navgraph sees the named
// binding pulled out of ./bus.
const { bus } = require('./bus');

// Handle a freshly-created item by announcing it.
function onItemCreated(item) {
  console.log('item created: ' + describe(item));
}

// Handle a deleted item by announcing the id that went away.
function onItemDeleted(payload) {
  console.log('item deleted: #' + payload.id);
}

// Build a short human string for an item. Shared by the handlers above.
function describe(item) {
  return (item && item.name) || 'unnamed';
}

// Wire the handlers to the shared bus. Called once at startup from server.js.
function registerHandlers() {
  bus.on('item.created', onItemCreated);
  bus.on('item.deleted', onItemDeleted);
}

module.exports = { registerHandlers };
