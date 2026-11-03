"""Prometheus metrics and the HTTP instrumentation middleware."""

from __future__ import annotations

import time

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

# Buckets tuned for a p95 latency SLO of 300 ms.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.5, 5.0)


class AppMetrics:
    """Holds all metrics on a dedicated registry (keeps tests isolated)."""

    def __init__(self, registry: CollectorRegistry | None = None) -> None:
        self.registry = registry or CollectorRegistry()
        self.requests = Counter(
            "http_requests_total",
            "Total HTTP requests",
            ["method", "path", "status"],
            registry=self.registry,
        )
        self.latency = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency in seconds",
            ["method", "path"],
            buckets=LATENCY_BUCKETS,
            registry=self.registry,
        )
        self.in_flight = Gauge(
            "http_requests_in_flight",
            "HTTP requests currently being served",
            registry=self.registry,
        )
        self.build_info = Gauge(
            "app_build_info",
            "Build information (value is always 1)",
            ["version", "git_sha", "environment"],
            registry=self.registry,
        )
        self.items = Gauge("app_items_total", "Items currently stored", registry=self.registry)


def route_template(request: Request) -> str:
    """Return the matched route path (e.g. /api/items/{item_id}) to bound label cardinality."""
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    return path if path else "unmatched"


class MetricsMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, metrics: AppMetrics) -> None:  # noqa: ANN001 - ASGI app
        super().__init__(app)
        self.metrics = metrics

    async def dispatch(self, request: Request, call_next) -> Response:  # noqa: ANN001
        if request.url.path == "/metrics":
            return await call_next(request)
        self.metrics.in_flight.inc()
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            elapsed = time.perf_counter() - start
            path = route_template(request)
            self.metrics.requests.labels(request.method, path, str(status)).inc()
            self.metrics.latency.labels(request.method, path).observe(elapsed)
            self.metrics.in_flight.dec()
