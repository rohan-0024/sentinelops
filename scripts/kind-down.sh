#!/usr/bin/env bash
# Stops (default) or deletes (--delete) the local kind cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
NODE=sentinelops-control-plane
if [[ "${1:-}" == "--delete" ]]; then
  kind delete cluster --name sentinelops
else
  docker stop "${NODE}" >/dev/null 2>&1 && echo "kind node stopped (state kept)" || echo "kind node not running"
fi
