import pytest
from fastapi.testclient import TestClient

from sentinel_app.config import Settings
from sentinel_app.main import create_app
from sentinel_app.metrics import AppMetrics


def make_settings(**overrides) -> Settings:
    base = dict(
        app_name="sentinelops-app",
        version="1.2.3",
        git_sha="abc1234",
        environment="test",
        fault_error_rate=0.0,
        fault_latency_ms=0.0,
    )
    base.update(overrides)
    return Settings(**base)


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(settings=make_settings(), metrics=AppMetrics()))
