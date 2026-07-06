"""Shared pytest fixtures for the users test-suite."""

from app.main import create_app


def client():
    """Return a bare app instance the tests can drive."""
    return create_app()
