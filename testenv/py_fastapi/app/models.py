"""Domain models for the users API."""


class User:
    """A single user record: an id plus profile fields."""

    def __init__(self, id: int, name: str, email: str) -> None:
        self.id = id
        self.name = name
        self.email = email

    def __repr__(self) -> str:
        return f"User(id={self.id!r}, name={self.name!r})"


def normalize_email(email: str) -> str:
    """Lower-case and trim a raw email string before storage."""
    return email.strip().lower()
