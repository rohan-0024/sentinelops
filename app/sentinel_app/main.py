"""FastAPI application: health/readiness probes, metrics, and a small items API."""

from __future__ import annotations

import asyncio
import random
import threading
from collections.abc import Callable

from fastapi import FastAPI, HTTPException, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from .config import Settings
from .metrics import AppMetrics, MetricsMiddleware


class ItemIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    quantity: int = Field(ge=0, le=1_000_000)


class Item(ItemIn):
    id: int


class ItemStore:
    """Thread-safe in-memory store (the service is stateless across replicas by design)."""

    def __init__(self) -> None:
        self._items: dict[int, Item] = {}
        self._next_id = 1
        self._lock = threading.Lock()

    def list(self) -> list[Item]:
        with self._lock:
            return list(self._items.values())

    def get(self, item_id: int) -> Item | None:
        with self._lock:
            return self._items.get(item_id)

    def create(self, data: ItemIn) -> Item:
        with self._lock:
            item = Item(id=self._next_id, **data.model_dump())
            self._items[item.id] = item
            self._next_id += 1
            return item

    def delete(self, item_id: int) -> bool:
        with self._lock:
            return self._items.pop(item_id, None) is not None

    def __len__(self) -> int:
        with self._lock:
            return len(self._items)


def create_app(
    settings: Settings | None = None,
    metrics: AppMetrics | None = None,
    rng: Callable[[], float] = random.random,
) -> FastAPI:
    settings = settings or Settings.from_env()
    metrics = metrics or AppMetrics()
    store = ItemStore()
    state = {"ready": True}

    app = FastAPI(title=settings.app_name, version=settings.version)
    app.add_middleware(MetricsMiddleware, metrics=metrics)
    metrics.build_info.labels(settings.version, settings.git_sha, settings.environment).set(1)

    async def inject_faults() -> None:
        if settings.fault_latency_ms > 0:
            await asyncio.sleep(settings.fault_latency_ms / 1000.0)
        if settings.fault_error_rate > 0 and rng() < settings.fault_error_rate:
            raise HTTPException(status_code=500, detail="injected fault")

    @app.get("/")
    async def root() -> dict:
        return {
            "service": settings.app_name,
            "version": settings.version,
            "git_sha": settings.git_sha,
            "environment": settings.environment,
        }

    @app.get("/health")
    async def health() -> dict:
        """Liveness: the process is up and the event loop responds."""
        return {"status": "ok"}

    @app.get("/ready")
    async def ready(response: Response) -> dict:
        """Readiness: the instance can take traffic (toggled during graceful drain)."""
        if not state["ready"]:
            response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
            return {"status": "not-ready"}
        return {"status": "ready"}

    @app.post("/admin/drain", status_code=status.HTTP_202_ACCEPTED)
    async def drain() -> dict:
        """Mark the instance not-ready so Kubernetes stops routing traffic to it."""
        state["ready"] = False
        return {"status": "draining"}

    @app.get("/metrics")
    async def prometheus_metrics() -> Response:
        metrics.items.set(len(store))
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    @app.get("/api/items", response_model=list[Item])
    async def list_items() -> list[Item]:
        await inject_faults()
        return store.list()

    @app.post("/api/items", response_model=Item, status_code=status.HTTP_201_CREATED)
    async def create_item(data: ItemIn) -> Item:
        await inject_faults()
        return store.create(data)

    @app.get("/api/items/{item_id}", response_model=Item)
    async def get_item(item_id: int) -> Item:
        await inject_faults()
        item = store.get(item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="item not found")
        return item

    @app.delete("/api/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
    async def delete_item(item_id: int) -> Response:
        await inject_faults()
        if not store.delete(item_id):
            raise HTTPException(status_code=404, detail="item not found")
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_app()
