// A tiny synchronous message bus so the catalog can announce changes without
// the routes knowing who is listening. CommonJS module. Handlers are keyed by
// a string event name (e.g. 'item.created'), which is what navgraph `events`
// pairs against the emit sites.
class MessageBus {
  constructor() {
    this.handlers = new Map();
  }

  // Register a handler for a named event. Multiple handlers may subscribe to
  // the same event; they fire in registration order.
  on(event, handler) {
    const list = this.handlers.get(event) || [];
    list.push(handler);
    this.handlers.set(event, list);
    return this;
  }

  // Publish a payload to every handler registered for the event.
  emit(event, payload) {
    const list = this.handlers.get(event) || [];
    for (const handler of list) {
      handler(payload);
    }
    return list.length;
  }

  // Drop all handlers for an event. Only used in tests today.
  // intentionally dead (fixture)
  off(event) {
    this.handlers.delete(event);
  }
}

// Process-wide singleton so producers and consumers share one bus.
const bus = new MessageBus();

module.exports = { MessageBus, bus };
