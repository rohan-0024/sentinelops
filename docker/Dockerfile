# syntax=docker/dockerfile:1.7
# Multi-stage build: deps are installed in a full Python image, then copied into a
# distroless, non-root runtime with no shell or package manager.
# Build context: ./app      Build: docker build -f docker/Dockerfile app/
# Base image tags are pinned literally (scanners cannot resolve ARG-based FROM).
# Keep in sync with PYTHON_BUILD_IMAGE / PYTHON_RUNTIME_IMAGE in versions.env.

# ---------- build stage ----------
FROM python:3.11.11-slim-bookworm AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /src
COPY requirements.txt .
# BuildKit cache mount keeps wheels between builds without baking them into a layer.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --target=/deps --only-binary=:all: -r requirements.txt
COPY sentinel_app/ ./sentinel_app/
RUN python -m compileall -q /deps /src/sentinel_app

# ---------- runtime stage ----------
FROM gcr.io/distroless/python3-debian12:nonroot AS runtime
ARG APP_VERSION=1.0.0
ARG GIT_SHA=dev
LABEL org.opencontainers.image.title="sentinelops-app" \
      org.opencontainers.image.source="https://github.com/rohan-0024/sentinelops" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.licenses="MIT"
ENV PYTHONPATH=/deps:/app \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    PORT=8000
WORKDIR /app
COPY --from=build --chown=65532:65532 /deps /deps
COPY --from=build --chown=65532:65532 /src/sentinel_app /app/sentinel_app
# distroless :nonroot already runs as 65532; stated explicitly for scanners and Kyverno.
USER 65532:65532
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/usr/bin/python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
ENTRYPOINT ["/usr/bin/python3", "-m", "sentinel_app.server"]
