#!/usr/bin/env bash
# Starts a local OCI registry for local mode (the kind "local registry" pattern).
#   Host (docker push):     localhost:5001/<image>
#   Inside kind / Jenkins:  kind-registry:5000/<image>   (same storage)
# Usage: scripts/local-registry.sh [up|down|status]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"

NAME=kind-registry
HOST_PORT=5001

up() {
  if [[ "$(docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || true)" != "true" ]]; then
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker run -d --restart=unless-stopped --name "${NAME}" \
      -p "127.0.0.1:${HOST_PORT}:5000" \
      -e REGISTRY_STORAGE_DELETE_ENABLED=true \
      -v sentinelops-registry:/var/lib/registry \
      --label project=sentinelops \
      "${REGISTRY_IMAGE}" >/dev/null
    echo "registry started on localhost:${HOST_PORT}"
  else
    echo "registry already running on localhost:${HOST_PORT}"
  fi
  # Join the kind network (created by `kind create cluster`) so nodes resolve kind-registry.
  if docker network inspect kind >/dev/null 2>&1; then
    docker network connect kind "${NAME}" 2>/dev/null || true
  fi
}

down() { docker rm -f "${NAME}" >/dev/null 2>&1 && echo "registry removed" || echo "registry not running"; }

status() { curl -fsS "http://localhost:${HOST_PORT}/v2/_catalog" && echo; }

case "${1:-up}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 [up|down|status]" >&2; exit 2 ;;
esac
