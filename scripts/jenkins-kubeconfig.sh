#!/usr/bin/env bash
# Copies the kind cluster's internal kubeconfig (API at sentinelops-control-plane:6443,
# reachable on the "kind" Docker network) into the Jenkins container and checks it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
SRC="${ROOT}/local/secrets/kubeconfig-internal"
J=sentinelops-jenkins

if [[ ! -s "${SRC}" ]]; then
  kind get kubeconfig --name sentinelops --internal > "${SRC}"
  chmod 600 "${SRC}"
fi
docker inspect "${J}" >/dev/null 2>&1 || { echo "Jenkins container not running - skipped"; exit 0; }
docker exec -u root "${J}" mkdir -p /var/jenkins_home/.kube
docker cp "${SRC}" "${J}:/var/jenkins_home/.kube/config"
docker exec -u root "${J}" sh -c 'chown -R jenkins:jenkins /var/jenkins_home/.kube && chmod 600 /var/jenkins_home/.kube/config'
echo "Jenkins kubeconfig installed; Jenkins sees:"
docker exec "${J}" kubectl get nodes | sed 's/^/    /'
