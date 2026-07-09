// Domain models for blog posts and their lifecycle. These types are shared by
// the api clients, the hooks, and the UI components.

/** Publication state a post can be in. */
export enum PostStatus {
  Draft = "draft",
  Published = "published",
  Archived = "archived",
}

/** A single blog post authored by a user account. */
export interface Post {
  id: number;
  authorId: number;
  title: string;
  body: string;
  status: PostStatus;
  tags: string[];
}

/** Fields accepted when creating a post; the id is server-assigned. */
export type NewPost = Omit<Post, "id">;

/** A single page of results returned by any list endpoint. Generic over the row type. */
export interface Page<T> {
  items: T[];
  total: number;
  cursor: string | null;
}

// intentionally dead (fixture): no module imports or references PostDraft.
/** Unused variant kept as a `navgraph unused` type target. */
export type PostDraft = Partial<Post> & { status: PostStatus.Draft };
