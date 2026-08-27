// Constructs that break heuristic parsers, gathered in one module.
// Nothing in the app imports this file: tests/golden/typescript.json records
// exactly which definitions and reference edges a correct indexer must find.

import { HttpClient } from "./api/http";
// Renamed named import, plus a type-only import of a re-exported type.
import { ok as succeed, fail } from "./models";
import type { Account, Result } from "./models";
import { Role } from "./types";
import { Store } from "./store/store";

/** Module-level constant a local below shadows. */
export const budget = 16;

/** Type alias, a mapped type and a conditional type over it. */
export type Patch<T> = { [K in keyof T]?: T[K] };
export type Unwrap<T> = T extends Result<infer V> ? V : never;

/** Discriminated union: the tag decides the payload. */
export type Event =
  | { kind: "created"; account: Account }
  | { kind: "removed"; id: number };

/** Interface with an index signature, a call signature and a method. */
export interface Sink {
  [key: string]: unknown;
  label: string;
  emit(event: Event): void;
}

/** Interface extending another, so the hierarchy has two levels. */
export interface AuditedSink extends Sink {
  audit(reason: string): void;
}

/** Abstract base with a protected member and an abstract method. */
export abstract class BaseLedger<T> {
  protected entries: T[] = [];
  static created = 0;

  constructor(protected readonly owner: string) {
    BaseLedger.created += 1;
  }

  /** Accessor pair over the protected array. */
  get size(): number {
    return this.entries.length;
  }

  set size(value: number) {
    this.entries.length = value;
  }

  abstract describe(): string;

  /** Concrete method the subclass calls through `super`. */
  add(entry: T): number {
    this.entries.push(entry);
    return this.entries.length;
  }
}

/** Subclass implementing an interface and calling into its base. */
export class AccountLedger extends BaseLedger<Account> implements AuditedSink {
  [key: string]: unknown;
  label = "accounts";

  private readonly cache = new Store<Account>();

  constructor(owner: string, private readonly client: HttpClient) {
    super(owner);
  }

  describe(): string {
    return `${this.owner}/${this.label}`;
  }

  /** Overrides the base and calls it through `super`. */
  add(entry: Account): number {
    this.cache.set(entry.id, entry);
    return super.add(entry);
  }

  emit(event: Event): void {
    if (event.kind === "created") {
      this.add(event.account);
    }
  }

  audit(reason: string): void {
    this.label = `${this.label}:${reason}`;
  }

  /** Method calling through a typed private member. */
  async pull(path: string): Promise<Result<Account[]>> {
    return this.client.get<Account[]>(path);
  }
}

/** Overload signatures followed by one implementation. */
export function describeRole(role: Role): string;
export function describeRole(role: Role, upper: boolean): string;
export function describeRole(role: Role, upper = false): string {
  const text = role === Role.Admin ? "admin" : "user";
  return upper ? text.toUpperCase() : text;
}

/** A named function, and an alias bound to a const and called through it. */
function doubleValue(value: number): number {
  return value * 2;
}

export const doubler = doubleValue;

/** An arrow function in a const: the closure-in-a-variable case. */
export const tripler = (value: number): number => value * 3;

/** A factory returning a named function expression. */
export function makeScaler(factor: number) {
  return function scaled(value: number): number {
    return value * factor;
  };
}

/** Async generator: `for await` over it below. */
export async function* pages(count: number): AsyncGenerator<number> {
  for (let i = 1; i <= count; i += 1) {
    yield i;
  }
}

/** The local `budget` hides the module-level `budget`. */
export function shadowBudget(n: number): number {
  const budget = 4;
  return n * budget;
}

/** Same name as models/user.ts's `fail`: two definitions sharing one name. */
function warn(message: string): string {
  return `warn:${message}`;
}

/** Code-shaped text in a template literal and in comments: data, not code. */
const BANNER = `
export class PhantomClass { ghost(): void {} }
export function phantomFromString(): number { return 0; }
`;
// export function phantomFromComment(): void {}

/** Drives every construct above from one place. */
export async function trickyRun(): Promise<number> {
  const http = new HttpClient("/api");
  const ledger = new AccountLedger("root", http);

  const account: Account = {
    id: 1,
    name: "root",
    role: Role.Admin,
    email: "root@example.com",
    active: true,
  };
  ledger.add(account);
  ledger.emit({ kind: "created", account });
  ledger.audit("boot");
  ledger.size = 1;

  const described = ledger.describe() + describeRole(Role.User, true);
  const pulled = await ledger.pull("/users");
  const wrapped = pulled.ok ? succeed(pulled.value) : fail<Account[]>("empty");

  const patch: Patch<Account> = { active: false };
  let counted = 0;
  for await (const page of pages(3)) {
    counted += page;
  }

  return (
    doubler(shadowBudget(budget)) +
    tripler(ledger.size) +
    makeScaler(2)(counted) +
    described.length +
    warn(String(wrapped.ok)).length +
    Object.keys(patch).length +
    BANNER.length +
    BaseLedger.created
  );
}
