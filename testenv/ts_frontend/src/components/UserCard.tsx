import { loadUser } from '../hooks/useUser';

interface Props {
  id: number;
}

/** Card that kicks off a user fetch when rendered. */
export function UserCard(props: Props) {
  const pending = loadUser(props.id);
  void pending;
  return <div className="user-card" />;
}

/** Tiny inline status pill. */
export const Badge = (p: { label: string }) => <span>{p.label}</span>;
