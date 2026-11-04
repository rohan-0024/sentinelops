#!/usr/bin/env bash
# Creates the enforced app namespace and installs/updates the SentinelOps Kyverno
# policies chart. Called by cluster-addons.sh; run alone with `make policies`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
MODE="${MODE:-local}"
CTX="${KUBE_CONTEXT:-kind-sentinelops}"
K=(kubectl --context "${CTX}")
H=(helm --kube-context "${CTX}")
ENVPY="python3 ${ROOT}/scripts/envfile.py"

"${K[@]}" create namespace sentinelops --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" label namespace sentinelops sentinelops.io/enforce=true --overwrite >/dev/null
PUB="${ROOT}/policy/keys/cosign.pub"
[[ -f "${PUB}" ]] || { echo "missing ${PUB} - run make cosign-keygen" >&2; exit 1; }
POLICY_VALUES=(-f "${ROOT}/k8s/charts/sentinelops-policies/values.yaml")
[[ -f "${ROOT}/k8s/charts/sentinelops-policies/values-${MODE}.yaml" ]] \
  && POLICY_VALUES+=(-f "${ROOT}/k8s/charts/sentinelops-policies/values-${MODE}.yaml")
if [[ "${MODE}" == aws ]]; then
  ECR="$(${ENVPY} get ECR_REPOSITORY_URL)"
  [[ -n "${ECR}" ]] || { echo "ECR_REPOSITORY_URL missing in .env" >&2; exit 1; }
  POLICY_VALUES+=(--set "allowedRepository=${ECR}")
fi
"${H[@]}" upgrade --install sentinelops-policies "${ROOT}/k8s/charts/sentinelops-policies" -n kyverno \
  "${POLICY_VALUES[@]}" --set-file cosignPublicKey="${PUB}" --wait --timeout 3m

"${K[@]}" get imagevalidatingpolicies,validatingpolicies 2>/dev/null | sed "s/^/    /" || true
