import type { Result } from "../models";
import { ok, fail } from "../models";

/** Options accepted by a single HTTP request. */
export interface RequestOptions {
  method: string;
  body?: unknown;
  headers?: Record<string, string>;
}

/**
 * Generic JSON HTTP client. Every method returns a typed `Result<T>` so callers
 * never touch a raw `Response`. Shared by the higher-level resource clients.
 */
export class HttpClient {
  constructor(private readonly baseUrl: string) {}

  /** Issue a request against `path` and decode the JSON body as `T`. */
  async request<T>(path: string, opts: RequestOptions): Promise<Result<T>> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method: opts.method,
      headers: { "Content-Type": "application/json", ...opts.headers },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    if (!res.ok) return fail<T>(`HTTP ${res.status}`);
    return ok<T>(await res.json());
  }

  /** GET helper that delegates to `request`. */
  get<T>(path: string): Promise<Result<T>> {
    return this.request<T>(path, { method: "GET" });
  }

  /** POST helper that delegates to `request`. */
  post<T>(path: string, body: unknown): Promise<Result<T>> {
    return this.request<T>(path, { method: "POST", body });
  }
}
