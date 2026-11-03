"""Runtime configuration read from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass

from . import __version__


def _float(name: str, default: float, lo: float | None = None, hi: float | None = None) -> float:
    raw = os.getenv(name, "")
    try:
        value = float(raw) if raw.strip() else default
    except ValueError:
        value = default
    if lo is not None:
        value = max(lo, value)
    if hi is not None:
        value = min(hi, value)
    return value


@dataclass(frozen=True)
class Settings:
    app_name: str
    version: str
    git_sha: str
    environment: str
    # Fault injection, used to demonstrate canary auto-rollback (Feature 3).
    fault_error_rate: float  # 0.0 - 1.0, fraction of /api requests returning 500
    fault_latency_ms: float  # extra latency added to /api requests

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            app_name=os.getenv("APP_NAME", "sentinelops-app"),
            version=os.getenv("APP_VERSION", __version__),
            git_sha=os.getenv("GIT_SHA", "dev"),
            environment=os.getenv("APP_ENV", "local"),
            fault_error_rate=_float("FAULT_ERROR_RATE", 0.0, 0.0, 1.0),
            fault_latency_ms=_float("FAULT_LATENCY_MS", 0.0, 0.0, 10_000.0),
        )
