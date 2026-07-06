"""Application entry point: build the FastAPI app and mount routers."""

from fastapi import FastAPI

from .routes.users import router

app = FastAPI(title="Users API")
app.include_router(router)


@app.get("/health")
def health():
    """Liveness probe used by the load balancer."""
    return {"status": "ok"}


def create_app() -> FastAPI:
    """Factory used by tests and the ASGI server."""
    return app
