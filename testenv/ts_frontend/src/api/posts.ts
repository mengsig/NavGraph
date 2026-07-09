import { HttpClient } from "./http";
import type { Post, NewPost, Page, Result } from "../models";

/**
 * Resource client for the `/api/posts` collection. Wraps a typed `HttpClient`
 * and exposes one method per backend route.
 */
export class PostClient {
  private http = new HttpClient("/api");

  /** GET /api/posts — list a page of posts, optionally after a cursor. */
  list(cursor?: string): Promise<Result<Page<Post>>> {
    const query = cursor ? `?cursor=${cursor}` : "";
    return this.http.get<Page<Post>>(`/posts${query}`);
  }

  /** GET /api/posts/:id — fetch a single post by id. */
  get(id: number): Promise<Result<Post>> {
    return this.http.get<Post>(`/posts/${id}`);
  }

  /** POST /api/posts — create a new post from a draft. */
  create(draft: NewPost): Promise<Result<Post>> {
    return this.http.post<Post>("/posts", draft);
  }
}
