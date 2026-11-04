#!/usr/bin/env bash
# Installs cluster add-ons (pinned charts) and SentinelOps policies, then gives
# Jenkins a kubeconfig. Works for local (kind) and aws (EKS) via MODE / KUBE_CONTEXT.
#   monitoring:     kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, KSM), Pushgateway
#   argo-rollouts:  progressive delivery controller + dashboard
#   kyverno:        admission controller + sentinelops-policies chart
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"
export PATH="${ROOT}/.bin:${PATH}"
MODE="${MODE:-local}"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  CTX="${KUBE_CONTEXT}"
elif [[ "${MODE}" == local ]]; then
  CTX=kind-sentinelops
else
  CTX="$(kubectl config current-context)"
fi
K=(kubectl --context "${CTX}")
H=(helm --kube-context "${CTX}")
ENVPY="python3 ${ROOT}/scripts/envfile.py"

step() { printf '\n\033[1;35m--> %s\033[0m\n' "$*"; }

step "helm repositories"
"${H[@]}" repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
"${H[@]}" repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
"${H[@]}" repo add kyverno https://kyverno.github.io/kyverno --force-update >/dev/null
"${H[@]}" repo update >/dev/null

step "monitoring: kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
"${K[@]}" create namespace monitoring --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
GRAFANA_PW="$(${ENVPY} get GRAFANA_ADMIN_PASSWORD)"
[[ -n "${GRAFANA_PW}" ]] || { echo "GRAFANA_ADMIN_PASSWORD missing in .env (run make init-env)" >&2; exit 1; }
"${K[@]}" -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="${GRAFANA_PW}" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${H[@]}" upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" -n monitoring \
  -f "${ROOT}/k8s/addons/kube-prometheus-stack-values.yaml" --wait --timeout 12m
if [[ -d "${ROOT}/monitoring" && -x "${ROOT}/scripts/monitoring-apply.sh" ]]; then
  bash "${ROOT}/scripts/monitoring-apply.sh"
fi

step "monitoring: pushgateway ${PUSHGATEWAY_CHART_VERSION}"
"${H[@]}" upgrade --install pushgateway prometheus-community/prometheus-pushgateway \
  --version "${PUSHGATEWAY_CHART_VERSION}" -n monitoring \
  -f "${ROOT}/k8s/addons/pushgateway-values.yaml" --wait --timeout 5m

step "argo-rollouts ${ARGO_ROLLOUTS_CHART_VERSION}"
"${H[@]}" upgrade --install argo-rollouts argo/argo-rollouts \
  --version "${ARGO_ROLLOUTS_CHART_VERSION}" -n argo-rollouts --create-namespace \
  -f "${ROOT}/k8s/addons/argo-rollouts-values.yaml" --wait --timeout 5m

step "kyverno ${KYVERNO_CHART_VERSION}"
"${H[@]}" upgrade --install kyverno kyverno/kyverno \
  --version "${KYVERNO_CHART_VERSION}" -n kyverno --create-namespace \
  -f "${ROOT}/k8s/addons/kyverno-values.yaml" --wait --timeout 8m

step "namespaces + sentinelops policies"
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

step "load generator"
sed "s#LOADGEN_IMAGE#${LOADGEN_IMAGE}#" "${ROOT}/k8s/loadgen.yaml" | "${K[@]}" apply -f - >/dev/null

if [[ "${MODE}" == local ]] && docker inspect sentinelops-jenkins >/dev/null 2>&1; then
  step "kubeconfig for Jenkins (internal API address)"
  docker exec -u root sentinelops-jenkins mkdir -p /var/jenkins_home/.kube
  docker cp "${ROOT}/local/secrets/kubeconfig-internal" sentinelops-jenkins:/var/jenkins_home/.kube/config
  docker exec -u root sentinelops-jenkins sh -c \
    'chown -R jenkins:jenkins /var/jenkins_home/.kube && chmod 600 /var/jenkins_home/.kube/config'
  docker exec sentinelops-jenkins kubectl get nodes -o wide | sed 's/^/    /'
fi

echo
echo "add-ons ready: Grafana http://localhost:30300 (admin / GRAFANA_ADMIN_PASSWORD in .env), Prometheus http://localhost:30090"
