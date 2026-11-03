#!/usr/bin/env bash
# Writes ansible/inventory/aws.ini from `terraform output` (envs/aws).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="$(terraform -chdir="${ROOT}/terraform/envs/aws" output -raw jenkins_public_ip 2>/dev/null || true)"
if [[ -z "${IP}" ]]; then
  echo "No jenkins_public_ip output. Run 'make aws-plan' and 'make aws-apply' first." >&2
  exit 1
fi
KEY="${ANSIBLE_SSH_KEY:-${HOME}/.ssh/labsuser.pem}"
[[ -f "${KEY}" ]] || echo "warning: SSH key ${KEY} not found (AWS Academy: Learner Lab -> AWS Details -> Download PEM; chmod 400)" >&2
cat > "${ROOT}/ansible/inventory/aws.ini" <<INI
[ci]
jenkins ansible_host=${IP}

[ci:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${KEY}
INI
echo "wrote ansible/inventory/aws.ini (jenkins -> ${IP})"
