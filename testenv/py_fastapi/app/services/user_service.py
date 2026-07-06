"""Business logic for reading and writing users."""

from ..models import User, normalize_email

_USERS: dict = {}


class UserService:
    """In-memory user store used by the routes layer."""

    def fetch(self, id: int):
        """Return the user with `id`, or None when absent."""
        row = self._query(id)
        if row is None:
            return None
        return User(id, row["name"], row["email"])

    def _query(self, id: int):
        """Look up the raw record backing a user id."""
        return _USERS.get(id)

    def create(self, name: str, email: str) -> User:
        """Persist and return a freshly created user."""
        clean = normalize_email(email)
        user = User(len(_USERS) + 1, name, clean)
        _USERS[user.id] = {"name": name, "email": clean}
        return user

    def remove(self, id: int) -> bool:
        """Delete a user by id; True when a row was removed."""
        if id in _USERS:
            del _USERS[id]
            return True
        return False


def _seed_demo_data() -> None:
    """Populate the store with fixtures for local development."""
    _USERS[1] = {"name": "Ada", "email": "ada@example.com"}
