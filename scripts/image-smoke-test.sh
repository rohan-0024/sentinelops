#!/usr/bin/env bash
# Runs the built image and checks /health, /ready, /metrics, non-root user.
# Usage: scripts/image-smoke-test.sh <image>
set -euo pipefail
IMAGE="${1:?image required}"
NAME="sentinelops-smoke-$$"
PORT="${SMOKE_PORT:-18000}"
cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "${NAME}" -p "127.0.0.1:${PORT}:8000" --read-only --cap-drop=ALL "${IMAGE}" >/dev/null

for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break
  sleep 1
done

fail() { echo "SMOKE FAIL: $*" >&2; docker logs "${NAME}" >&2 || true; exit 1; }

curl -fsS "http://127.0.0.1:${PORT}/health" | grep -q '"ok"' || fail "/health"
curl -fsS "http://127.0.0.1:${PORT}/ready" | grep -q '"ready"' || fail "/ready"
curl -fsS "http://127.0.0.1:${PORT}/metrics" | grep -q '^app_build_info' || fail "/metrics"
USER_ID="$(docker inspect -f '{{.Config.User}}' "${IMAGE}")"
[[ "${USER_ID}" == "65532:65532" ]] || fail "image user is '${USER_ID}', expected 65532:65532"
SIZE="$(docker image inspect -f '{{.Size}}' "${IMAGE}")"
echo "SMOKE OK: health/ready/metrics respond, runs as ${USER_ID}, read-only rootfs, size $((SIZE / 1024 / 1024)) MB"
