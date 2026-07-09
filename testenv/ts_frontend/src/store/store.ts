import type { Id } from "../types";

/** Minimal in-memory keyed cache, generic over the stored value type. */
export class Store<T> {
  private items = new Map<Id, T>();

  /** Insert or overwrite the entry for `id`. */
  set(id: Id, value: T): void {
    this.items.set(id, value);
  }

  /** Read the entry for `id`, or undefined if none is cached. */
  get(id: Id): T | undefined {
    return this.items.get(id);
  }

  /** Number of entries currently cached. */
  size(): number {
    return this.items.size;
  }
}

// intentionally dead (fixture): nothing references this module-private helper.
/** Unused debug formatter kept as a `navgraph unused` function target. */
function debugDump<T>(store: Store<T>): string {
  return `Store(size=${store.size()})`;
}
