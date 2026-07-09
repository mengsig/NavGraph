import { loadPosts } from "../hooks/usePosts";
import type { Post } from "../models";
import { PostStatus } from "../models";

interface PostListProps {
  cursor?: string;
}

/** Small pill rendering a post's publication status. */
export const StatusTag = (props: { status: PostStatus }) => (
  <span className={`tag tag-${props.status}`}>{props.status}</span>
);

/** One row in the post list; composes {@link StatusTag}. */
export const PostRow = (props: { post: Post }) => (
  <li className="post-row">
    <span className="title">{props.post.title}</span>
    <StatusTag status={props.post.status} />
  </li>
);

/** Kicks off a page load when rendered. */
export const PostList = (props: PostListProps) => {
  const pending = loadPosts(props.cursor);
  void pending;
  return <ul className="post-list" />;
};
