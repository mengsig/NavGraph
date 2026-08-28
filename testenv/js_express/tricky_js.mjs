// Constructs that break heuristic parsers, gathered in one ES module.
// Nothing in the app imports this file: tests/golden/javascript.json records
// exactly which definitions and reference edges a correct indexer must find.

// Default import, named import, and a renamed named import in one place.
import axios from 'axios';
import { formatItem, formatStatus as renderStatus } from './format.mjs';
// Namespace import of a barrel that itself re-exports from three modules.
import * as api from './api.mjs';

// Module-level constant a local below shadows.
const budget = 16;

// A class with a private field, static members, accessors and a generator.
export class Ledger {
  // Static member and a static factory.
  static created = 0;

  static blank(owner) {
    return new Ledger(owner, []);
  }

  #entries;

  constructor(owner, entries) {
    this.owner = owner;
    this.#entries = entries;
    Ledger.created += 1;
  }

  // Accessor pair over the private field.
  get size() {
    return this.#entries.length;
  }

  set size(value) {
    this.#entries.length = value;
  }

  // Signature split over three lines, with a default argument.
  post(
    label,
    amount = 0,
  ) {
    const entry = { label, amount };
    this.#entries.push(entry);
    return entry;
  }

  // Generator method.
  *[Symbol.iterator]() {
    for (const entry of this.#entries) {
      yield entry;
    }
  }

  // Callable-ish: an ordinary method reached through a typed receiver below.
  total(scale) {
    let sum = 0;
    for (const entry of this) {
      sum += entry.amount * scale;
    }
    return sum;
  }
}

// Subclass calling into its base through super.
export class TaggedLedger extends Ledger {
  constructor(owner, tag) {
    super(owner, []);
    this.tag = tag;
  }

  post(label, amount) {
    const entry = super.post(`${this.tag}:${label}`, amount);
    return entry;
  }
}

// Object literal whose values are methods, arrows and a shorthand method.
export const formatters = {
  plain(entry) {
    return `${entry.label}=${entry.amount}`;
  },
  loud: (entry) => formatters.plain(entry).toUpperCase(),
  nested: {
    quiet(entry) {
      return formatters.plain(entry).toLowerCase();
    },
  },
};

// A named function, then an alias bound to a const and called only through it.
function doubleValue(value) {
  return value * 2;
}

const doubler = doubleValue;

// An arrow function in a const: the "closure stored in a variable" case.
const tripler = (value) => value * 3;

// A factory returning a closure.
function makeScaler(factor) {
  return function scaled(value) {
    return value * factor;
  };
}

// A plain generator function.
function* countTo(n) {
  for (let i = 1; i <= n; i += 1) {
    yield i;
  }
}

// The local `budget` hides the module-level `budget`.
function shadowBudget(n) {
  const budget = 4;
  return n * budget;
}

// Prototype-style method attached after the fact.
function Counter() {
  this.calls = 0;
}

Counter.prototype.bump = function bump() {
  this.calls += 1;
  return this.calls;
};

// Code-shaped text in a template literal and in comments: data, not code.
const BANNER = `
export function phantomFromString() {}
class PhantomClass { ghost() {} }
`;
// export function phantomFromComment() {}

// Same name as adminRoutes.js's module-private helper: two file-local
// definitions sharing one name in two files.
function purgeAll(ledger) {
  ledger.size = 0;
  return ledger.size;
}

// Async function awaiting a client call through the re-export barrel.
export async function syncAll(client) {
  const items = await client.list();
  const created = await api.createItem(items[0]);
  return renderStatus(items.length) + formatItem(created);
}

// Drives every construct above from one place.
export async function trickyRun() {
  const ledger = Ledger.blank('anon');
  ledger.post('first', 500);
  ledger.post('second', 250);

  const tagged = new TaggedLedger('anon', 'tag');
  tagged.post('third', 125);

  const [first, ...rest] = [...ledger];
  const { label, amount = 0 } = first;

  const loud = formatters.loud(first);
  const quiet = formatters.nested.quiet(first);
  const scaled = makeScaler(3)(ledger.total(2));

  let counted = 0;
  for (const i of countTo(3)) {
    counted += i;
  }

  const counter = new Counter();
  counter.bump();

  const remaining = purgeAll(tagged);
  const synced = await syncAll(new api.CatalogClient('/api'));
  const posted = await axios.post('/items', { label });

  return (
    doubler(shadowBudget(budget)) +
    tripler(amount) +
    loud.length +
    quiet.length +
    scaled +
    counted +
    rest.length +
    remaining +
    synced.length +
    BANNER.length +
    posted.status
  );
}
