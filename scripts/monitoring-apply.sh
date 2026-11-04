#!/usr/bin/env bash
# Ships monitoring-as-code to the cluster (local or AWS):
#   alertmanager  render config from .env -> Secret alertmanager-sentinelops (used by kps)
#   rules         monitoring/prometheus/*.rules.yaml -> PrometheusRule CRs
#   dashboards    monitoring/grafana/dashboards/*.json -> ConfigMaps (grafana_dashboard=1)
# Usage: scripts/monitoring-apply.sh [alertmanager] [rules] [dashboards]   (default: all)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
PY="${ROOT}/.venv/bin/python"
[[ -x "${PY}" ]] || PY=python3
NS=monitoring
WHAT=("$@")
[[ ${#WHAT[@]} -eq 0 ]] && WHAT=(alertmanager rules dashboards)

"${K[@]}" create namespace "${NS}" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null

for item in "${WHAT[@]}"; do
  case "${item}" in
    alertmanager)
      # Values come from .env; nothing is written to disk.
      # shellcheck disable=SC1091
      cfg="$(set -a; if [[ -f "${ROOT}/.env" ]]; then . "${ROOT}/.env"; fi; set +a; cd "${ROOT}" && "${PY}" -m tools.monitoring.alertmanager)"
      "${K[@]}" -n "${NS}" create secret generic alertmanager-sentinelops \
        --from-literal=alertmanager.yaml="${cfg}" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
      echo "alertmanager config applied (receivers: $(grep -cE 'telegram_configs|slack_configs' <<<"${cfg}") chat integration(s))"
      ;;
    rules)
      for f in "${ROOT}"/monitoring/prometheus/*.rules.yaml; do
        name="$(basename "${f}" .rules.yaml)"
        "${PY}" - "${f}" "${name}" <<'EOF' | "${K[@]}" apply -f - >/dev/null
import sys, yaml
path, name = sys.argv[1], sys.argv[2]
spec = yaml.safe_load(open(path))
print(yaml.safe_dump({
    "apiVersion": "monitoring.coreos.com/v1",
    "kind": "PrometheusRule",
    "metadata": {"name": name, "namespace": "monitoring",
                 "labels": {"app.kubernetes.io/part-of": "sentinelops"}},
    "spec": {"groups": spec["groups"]},
}, sort_keys=False))
EOF
        echo "PrometheusRule ${name} applied"
      done
      ;;
    dashboards)
      for f in "${ROOT}"/monitoring/grafana/dashboards/*.json; do
        name="dashboard-$(basename "${f}" .json)"
        "${K[@]}" -n "${NS}" create configmap "${name}" --from-file="$(basename "${f}")=${f}" \
          --dry-run=client -o yaml \
          | "${K[@]}" label --local -f - grafana_dashboard=1 -o yaml \
          | "${K[@]}" annotate --local -f - grafana_folder=SentinelOps -o yaml \
          | "${K[@]}" apply -f - >/dev/null
        echo "dashboard ${name} applied"
      done
      ;;
    *) echo "unknown item ${item} (alertmanager|rules|dashboards)" >&2; exit 2 ;;
  esac
done
