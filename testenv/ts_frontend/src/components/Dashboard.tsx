import { UserCard } from "./UserCard";
import { PostList } from "./PostList";
import { fetchAccounts } from "../api";
import type { Account } from "../models";

interface DashboardProps {
  userId: number;
}

/** Top-level admin dashboard tying the user and post views together. */
export function Dashboard(props: DashboardProps) {
  const accounts: Promise<Account[]> = fetchAccounts();
  void accounts;
  return (
    <main className="dashboard">
      <UserCard id={props.userId} />
      <PostList />
    </main>
  );
}
