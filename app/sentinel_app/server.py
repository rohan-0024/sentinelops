"""Container entrypoint (distroless has no shell, so we start uvicorn from Python)."""

from __future__ import annotations

import os

import uvicorn


def main() -> None:
    uvicorn.run(
        "sentinel_app.main:app",
        host=os.getenv("HOST", "0.0.0.0"),  # noqa: S104 - must bind all interfaces inside the pod
        port=int(os.getenv("PORT", "8000")),
        log_level=os.getenv("LOG_LEVEL", "info"),
        access_log=os.getenv("ACCESS_LOG", "false").lower() == "true",
        proxy_headers=True,
    )


if __name__ == "__main__":
    main()
