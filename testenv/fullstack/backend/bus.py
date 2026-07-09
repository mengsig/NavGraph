"""A minimal in-process pub/sub message bus.

Handlers subscribe to a string event key with :func:`on`; publishers fire a key
with :func:`emit`. This is the backend half of the cross-language event wiring:
the TypeScript client emits keys this backend subscribes to, and subscribes to
keys this backend emits.
"""

_subscribers = {}


def on(event, handler):
    """Register ``handler`` to run whenever ``event`` is emitted."""
    _subscribers.setdefault(event, []).append(handler)
    return handler


def emit(event, payload):
    """Invoke every handler registered for ``event`` with ``payload``."""
    for handler in _subscribers.get(event, []):
        handler(payload)


def clear():
    """Drop all subscriptions (used between tests)."""
    _subscribers.clear()


# intentionally dead (fixture): no code calls this private counter helper.
def _subscriber_count(event):
    """How many handlers are bound to ``event``. Debug aid, never wired up."""
    return len(_subscribers.get(event, []))
