#!/usr/bin/env bash
# Pipeline stage 11 (and `make deploy`): canary deployment through Argo Rollouts.
#   scripts/deploy.sh <image@sha256:digest> [extra helm args, e.g. --set fault.errorRate=0.5]
# Canary pause per step depends on the Deployment Risk Score decision:
#   auto (DRS < 30) -> 15 s     canary (30-60) -> 60 s     unset -> chart default
# Exit code 1 means the analysis failed and Argo Rollouts already rolled back.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
IMAGE="${1:?usage: deploy.sh <registry/repo@sha256:digest> [helm args...]}"
shift
MODE="${SENTINELOPS_MODE:-${MODE:-local}}"
NS=sentinelops
APP=sentinelops-app
CHART="${ROOT}/k8s/charts/sentinelops-app"

case "${DRS_DECISION:-}" in
  auto) PAUSE=15 ;;
  canary) PAUSE=60 ;;
  *) PAUSE="" ;;
esac

ARGS=(-f "${CHART}/values.yaml" -f "${CHART}/values-${MODE}.yaml" --set "image.ref=${IMAGE}")
[[ -n "${PAUSE}" ]] && ARGS+=(--set "canary.pauseSeconds=${PAUSE}")

# Preflight: without a kubeconfig, kubectl/helm silently default to http://localhost:8080
# (inside the Jenkins container that is Jenkins itself). Fail with a clear message instead.
if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  echo "ERROR: no Kubernetes API reachable (KUBECONFIG=${KUBECONFIG:-unset}, context=$(kubectl config current-context 2>/dev/null || echo none))." >&2
  echo "       Local mode: run 'make local-up' on the laptop (creates the kind cluster and copies the kubeconfig into Jenkins)." >&2
  exit 1
fi

echo "deploying ${IMAGE} (mode=${MODE}, drs=${DRS_SCORE:-n/a}/${DRS_DECISION:-n/a}, pause=${PAUSE:-default})"
helm upgrade --install "${APP}" "${CHART}" -n "${NS}" "${ARGS[@]}" "$@"

if ! kubectl argo rollouts status "${APP}" -n "${NS}" --timeout 15m; then
  echo
  kubectl argo rollouts get rollout "${APP}" -n "${NS}" || true
  echo
  denied="$(kubectl get events -n "${NS}" --field-selector reason=FailedCreate \
    -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -i "admission webhook" | tail -n 3 || true)"
  if [[ -n "${denied}" ]]; then
    echo "DEPLOY BLOCKED BY ADMISSION POLICY (Kyverno) - pods were never created:"
    printf '  %s\n' "${denied}"
  else
    echo "CANARY FAILED: SLO analysis did not pass. Argo Rollouts aborted the rollout and"
    echo "restored the stable version automatically (no human action)."
  fi
  exit 1
fi
kubectl argo rollouts get rollout "${APP}" -n "${NS}" | head -n 25
echo "rollout healthy: ${IMAGE}"
