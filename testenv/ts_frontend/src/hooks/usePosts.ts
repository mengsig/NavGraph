import { PostClient } from "../api";
import type { Post, Page, Result } from "../models";
import { Store } from "../store/store";

// One shared client and one shared cache for the whole hook module.
const client = new PostClient();
const cache = new Store<Post>();

/** Load a page of posts through the shared client. */
export function loadPosts(cursor?: string): Promise<Result<Page<Post>>> {
  return client.list(cursor);
}

/** Load one post by id, returning a cached copy when present. */
export async function loadPost(id: number): Promise<Post | null> {
  const cached = cache.get(id);
  if (cached) return cached;
  const result = await client.get(id);
  if (result.ok) {
    cache.set(id, result.value);
    return result.value;
  }
  return null;
}
