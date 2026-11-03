from sentinel_app import __version__
from sentinel_app.config import Settings


def test_defaults(monkeypatch):
    for var in ("APP_NAME", "APP_VERSION", "GIT_SHA", "APP_ENV", "FAULT_ERROR_RATE", "FAULT_LATENCY_MS"):
        monkeypatch.delenv(var, raising=False)
    s = Settings.from_env()
    assert s.app_name == "sentinelops-app"
    assert s.version == __version__
    assert s.git_sha == "dev"
    assert s.environment == "local"
    assert s.fault_error_rate == 0.0 and s.fault_latency_ms == 0.0


def test_env_overrides(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "2.0.0")
    monkeypatch.setenv("GIT_SHA", "deadbee")
    monkeypatch.setenv("FAULT_ERROR_RATE", "0.25")
    monkeypatch.setenv("FAULT_LATENCY_MS", "120")
    s = Settings.from_env()
    assert (s.version, s.git_sha, s.fault_error_rate, s.fault_latency_ms) == ("2.0.0", "deadbee", 0.25, 120.0)


def test_fault_values_are_clamped_and_garbage_tolerated(monkeypatch):
    monkeypatch.setenv("FAULT_ERROR_RATE", "7")
    monkeypatch.setenv("FAULT_LATENCY_MS", "-5")
    s = Settings.from_env()
    assert s.fault_error_rate == 1.0 and s.fault_latency_ms == 0.0
    monkeypatch.setenv("FAULT_ERROR_RATE", "not-a-number")
    assert Settings.from_env().fault_error_rate == 0.0
