from fastapi.testclient import TestClient

from sentinel_app.main import create_app
from sentinel_app.metrics import AppMetrics

from .conftest import make_settings


def test_root_reports_build_info(client):
    body = client.get("/").json()
    assert body == {
        "service": "sentinelops-app",
        "version": "1.2.3",
        "git_sha": "abc1234",
        "environment": "test",
    }


def test_health_and_ready(client):
    assert client.get("/health").json() == {"status": "ok"}
    r = client.get("/ready")
    assert r.status_code == 200 and r.json() == {"status": "ready"}


def test_drain_makes_instance_not_ready(client):
    assert client.post("/admin/drain").status_code == 202
    r = client.get("/ready")
    assert r.status_code == 503
    assert r.json() == {"status": "not-ready"}
    # liveness is unaffected by draining
    assert client.get("/health").status_code == 200


def test_items_crud_lifecycle(client):
    assert client.get("/api/items").json() == []
    created = client.post("/api/items", json={"name": "widget", "quantity": 3})
    assert created.status_code == 201
    item = created.json()
    assert item == {"id": 1, "name": "widget", "quantity": 3}
    assert client.get("/api/items/1").json() == item
    assert client.get("/api/items").json() == [item]
    assert client.delete("/api/items/1").status_code == 204
    assert client.get("/api/items/1").status_code == 404
    assert client.delete("/api/items/1").status_code == 404


def test_ids_increment(client):
    a = client.post("/api/items", json={"name": "a", "quantity": 1}).json()
    b = client.post("/api/items", json={"name": "b", "quantity": 2}).json()
    assert (a["id"], b["id"]) == (1, 2)


def test_validation_rejects_bad_payloads(client):
    assert client.post("/api/items", json={"name": "", "quantity": 1}).status_code == 422
    assert client.post("/api/items", json={"name": "x", "quantity": -1}).status_code == 422
    assert client.post("/api/items", json={"quantity": 1}).status_code == 422
    assert client.get("/api/items/not-a-number").status_code == 422


def test_fault_injection_returns_500_when_rng_below_rate():
    app = create_app(settings=make_settings(fault_error_rate=0.5), metrics=AppMetrics(), rng=lambda: 0.1)
    c = TestClient(app)
    r = c.get("/api/items")
    assert r.status_code == 500
    assert r.json() == {"detail": "injected fault"}
    # probes are never fault-injected, so Kubernetes still sees the pod as healthy
    assert c.get("/health").status_code == 200


def test_fault_injection_passes_when_rng_above_rate():
    app = create_app(settings=make_settings(fault_error_rate=0.5), metrics=AppMetrics(), rng=lambda: 0.9)
    assert TestClient(app).get("/api/items").status_code == 200


def test_latency_injection_slows_api():
    import time

    app = create_app(settings=make_settings(fault_latency_ms=50), metrics=AppMetrics())
    c = TestClient(app)
    start = time.perf_counter()
    assert c.get("/api/items").status_code == 200
    assert time.perf_counter() - start >= 0.05
