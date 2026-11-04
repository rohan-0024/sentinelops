#!/usr/bin/env bash
# Creates (or restarts) the local kind cluster and wires it to the local registry.
#   - cluster "sentinelops" from k8s/kind/kind-config.yaml (pinned node image)
#   - containerd: kind-registry:5000 served over plain HTTP
#   - kubeconfig for the laptop (~/.kube/config context kind-sentinelops) and an
#     internal one for Jenkins (server https://sentinelops-control-plane:6443)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"
export PATH="${ROOT}/.bin:${PATH}"
NAME=sentinelops
NODE="${NAME}-control-plane"
REGISTRY=kind-registry:5000

if kind get clusters 2>/dev/null | grep -qx "${NAME}"; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "${NODE}" 2>/dev/null)" != "true" ]]; then
    echo "starting existing kind cluster ${NAME}"
    docker start "${NODE}" >/dev/null
  else
    echo "kind cluster ${NAME} already running"
  fi
else
  kind create cluster --name "${NAME}" --image "${KIND_NODE_IMAGE}" \
    --config "${ROOT}/k8s/kind/kind-config.yaml" --wait 120s
fi

# Plain-HTTP registry config inside the node (idempotent).
docker exec "${NODE}" mkdir -p "/etc/containerd/certs.d/${REGISTRY}"
docker exec -i "${NODE}" sh -c "cat > /etc/containerd/certs.d/${REGISTRY}/hosts.toml" <<EOF
[host."http://${REGISTRY}"]
  capabilities = ["pull", "resolve"]
EOF

kind export kubeconfig --name "${NAME}" >/dev/null
mkdir -p "${ROOT}/local/secrets"
kind get kubeconfig --name "${NAME}" --internal > "${ROOT}/local/secrets/kubeconfig-internal"
chmod 600 "${ROOT}/local/secrets/kubeconfig-internal"

# Advertise the registry to tools that read the KEP-1755 ConfigMap.
kubectl --context "kind-${NAME}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5001"
    hostFromClusterNetwork: "${REGISTRY}"
EOF

kubectl --context "kind-${NAME}" wait --for=condition=Ready node --all --timeout=180s
echo "kind cluster ${NAME} ready (context kind-${NAME})"
