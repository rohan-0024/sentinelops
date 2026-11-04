#!/usr/bin/env bash
# Pipeline stage 12: smoke test the deployed service, then run the chaos gate
# (tools/chaos, Phase 7) when it exists.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
MODE="${SENTINELOPS_MODE:-${MODE:-local}}"
NS=sentinelops
PF_PID=""
cleanup() {
  if [[ -n "${PF_PID}" ]]; then kill "${PF_PID}" 2>/dev/null || true; fi
}
trap cleanup EXIT

if [[ -z "${APP_URL:-}" ]]; then
  if [[ "${MODE}" == local ]] && getent hosts sentinelops-control-plane >/dev/null 2>&1; then
    APP_URL=http://sentinelops-control-plane:30080   # from the Jenkins container (kind network)
  elif [[ "${MODE}" == local ]]; then
    APP_URL=http://localhost:30080                   # from the laptop
  else
    kubectl -n "${NS}" port-forward svc/sentinelops-app 18080:80 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3
    APP_URL=http://127.0.0.1:18080
  fi
fi
echo "smoke testing ${APP_URL}"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
curl -fsS --retry 10 --retry-delay 2 --retry-all-errors "${APP_URL}/health" | grep -q '"ok"' || fail "/health"
curl -fsS "${APP_URL}/ready" | grep -q '"ready"' || fail "/ready"
created="$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{"name":"smoke","quantity":1}' "${APP_URL}/api/items")"
id="$(printf '%s' "${created}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" || fail "create item"
# Requests are load-balanced across replicas with in-memory stores; just check the API answers.
curl -fsS -o /dev/null -w '%{http_code}' "${APP_URL}/api/items" | grep -q 200 || fail "list items"
metrics="$(curl -fsS "${APP_URL}/metrics")"
grep -q '^app_build_info' <<<"${metrics}" || fail "/metrics"
if [[ -n "${GIT_SHA:-}" ]]; then
  # Load balancing may hit a pod of the previous revision only before promotion completes; after
  # `rollout status` it must be the new revision.
  grep -q "git_sha=\"${GIT_SHA}\"" <<<"${metrics}" || fail "deployed revision is not ${GIT_SHA}"
fi
echo "SMOKE OK (item ${id} created, revision ${GIT_SHA:-unknown})"

if [[ -f "${ROOT}/tools/chaos/__main__.py" ]]; then
  (cd "${ROOT}" && python3 -m tools.chaos --namespace "${NS}" --app sentinelops-app --url "${APP_URL}")
else
  echo "chaos gate: not installed yet (Phase 7) - skipped"
fi
