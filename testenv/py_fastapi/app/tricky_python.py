"""Constructs that break heuristic parsers, gathered in one module.

Nothing in the app imports this file: `tests/golden/python.json` records exactly
which definitions and reference edges a correct indexer must find here.
"""

from __future__ import annotations

import functools
from dataclasses import dataclass
from typing import Callable, Generic, Iterator, Protocol, TypeVar

# Aliased import, and a `from ... import x as y` rename of a real symbol.
from . import utils as util_mod
from .config import DEFAULT_PAGE_SIZE as PAGE_SIZE
from .models import Money, User
from .utils import clamp as bound

T = TypeVar("T")

#: Module-level constant a local below shadows.
budget = 16


class Formatter(Protocol):
    """A protocol: structural interface with no inheritance link."""

    def render(self, value: str) -> str:
        ...


class UpperFormatter:
    """Implements `Formatter` structurally, without naming it."""

    def render(self, value: str) -> str:
        return value.upper()


def tagged(prefix: str) -> Callable:
    """Parameterized decorator: a decorator factory, two levels of nesting."""

    def decorate(func: Callable) -> Callable:
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            return f"{prefix}:{func(*args, **kwargs)}"

        return wrapper

    return decorate


class Ledger(Generic[T]):
    """Generic container with a nested class, properties and dunder methods."""

    class Entry:
        """Nested type: `Ledger.Entry`."""

        def __init__(self, label: str, amount: Money) -> None:
            self.label = label
            self.amount = amount

        def scaled(self, factor: int) -> Money:
            return Money(self.amount.amount * factor, self.amount.currency)

    #: Class attribute, distinct from the instance attributes below.
    created = 0

    def __init__(self, owner: User) -> None:
        self.owner = owner
        self._entries: list[Ledger.Entry] = []
        Ledger.created += 1

    @property
    def size(self) -> int:
        """Getter half of a property pair."""
        return len(self._entries)

    @size.setter
    def size(self, value: int) -> None:
        """Setter half: truncates rather than grows."""
        del self._entries[value:]

    @staticmethod
    def blank(owner: User) -> "Ledger[T]":
        """Static method used as an alternate constructor."""
        return Ledger(owner)

    @classmethod
    def for_email(cls, email: str) -> "Ledger[T]":
        """Class method reaching a module-level function in another file."""
        return cls(User(0, "anon", email))

    def post(
        self,
        label: str,
        amount: Money,
    ) -> "Ledger.Entry":
        """Signature split over four lines; returns the nested type."""
        entry = Ledger.Entry(label, amount)
        self._entries.append(entry)
        return entry

    def __add__(self, other: "Ledger[T]") -> "Ledger[T]":
        """Operator overload: merges two ledgers."""
        merged = Ledger(self.owner)
        merged._entries = self._entries + other._entries
        return merged

    def __call__(self, factor: int) -> Money:
        """Callable instance: `ledger(2)` totals every entry, scaled."""
        total = Money(0, "USD")
        for entry in self._entries:
            total = total.add(entry.scaled(factor))
        return total

    def __iter__(self) -> Iterator["Ledger.Entry"]:
        """Generator method: `yield` makes this a generator function."""
        for entry in self._entries:
            yield entry


@dataclass
class Quota:
    """The near-miss for shadowing: a field spelled like the module constant."""

    budget: int = 4

    def scale(self, n: int) -> int:
        return n * self.budget


#: A function bound to a name, then called only through that name.
def _double(value: int) -> int:
    return value * 2


doubler = _double

#: A lambda in a module-level variable.
tripler = lambda value: value * 3


def shadow_budget(n: int) -> int:
    """The local `budget` hides the module-level `budget`."""
    budget = 4
    return n * budget


async def fetch_total(ledger: Ledger[int]) -> Money:
    """Async function awaiting another coroutine."""
    return await _resolve(ledger)


async def _resolve(ledger: Ledger[int]) -> Money:
    return ledger(1)


def format_all(entries: list[Ledger.Entry], formatter: Formatter) -> list[str]:
    """Method call on a protocol-typed parameter."""
    return [formatter.render(entry.label) for entry in entries]


BANNER = """
def phantom_from_string():
    class PhantomClass:
        pass
@app.get("/phantom-py")
"""
# def phantom_from_comment(): pass


@tagged("run")
def tricky_run() -> int:
    """Drives every construct above from one place."""
    ledger = Ledger.for_email("a@example.com")
    ledger.post("first", Money(500))
    ledger.post("second", Money(250))
    blank = Ledger.blank(ledger.owner)
    merged = ledger + blank

    total = merged(2)
    count = merged.size
    merged.size = 1

    first, *rest = list(iter(merged))
    scaled = first.scaled(3)

    labels = format_all([first], UpperFormatter())
    page = util_mod.make_paginator(PAGE_SIZE)([1, 2, 3], 1)
    capped = bound(count, 0, 10)

    return (
        total.amount
        + scaled.amount
        + len(labels)
        + len(page)
        + capped
        + doubler(shadow_budget(budget))
        + tripler(Quota().scale(2))
        + len(BANNER)
    )
