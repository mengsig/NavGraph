from dataclasses import dataclass


@dataclass
class User:
    name: str
    age: int = 0
    mapping = {
        key: default_value,
    }


def make_default():
    return 0


def fetch_user():
    return None


def outer():
    def inner(value=make_default()):
        return fetch_user()

    return inner()
