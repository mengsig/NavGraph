"""HTTP routes for the users resource."""

from fastapi import APIRouter

from ..services.user_service import UserService

router = APIRouter(prefix="/api/users")


@router.get("/{id}")
def get_user(id: int):
    """Fetch a single user by id."""
    svc = UserService()
    return svc.fetch(id)


@router.post("")
def create_user(name: str, email: str):
    """Create a new user from the submitted fields."""
    svc = UserService()
    return svc.create(name, email)


@router.delete("/{id}")
def delete_user(id: int):
    """Remove the user with the given id."""
    svc = UserService()
    return svc.remove(id)
