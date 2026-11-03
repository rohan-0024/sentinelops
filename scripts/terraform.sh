#!/usr/bin/env bash
# Terraform helper used by the Makefile.
#   fmt | validate | lint | local | plan | apply | destroy | bootstrap-plan | bootstrap-apply
# `apply`, `destroy` and `bootstrap-apply` are gated behind typing APPLY / DESTROY.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${ROOT}/terraform"
AWS_DIR="${TF}/envs/aws"
REPORTS="${ROOT}/reports"
mkdir -p "${REPORTS}"

roots=("${TF}/bootstrap" "${TF}/envs/aws" "${TF}/envs/local")
modules=("${TF}"/modules/*)

need_aws_creds() {
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    cat >&2 <<'EOF'
No valid AWS credentials. For AWS Academy:
  1. Learner Lab -> Start Lab -> wait for the green dot -> "AWS Details" -> "AWS CLI: Show"
  2. Paste the block into ~/.aws/credentials (inside WSL)   -- never into git or chat
  3. Re-run this target. Credentials expire when the lab session ends (~4h).
EOF
    exit 1
  fi
  aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
}

need_files() {
  for f in terraform.tfvars backend.hcl; do
    if [[ ! -f "${AWS_DIR}/${f}" ]]; then
      echo "Missing terraform/envs/aws/${f} - copy ${f}.example and fill it in." >&2
      exit 1
    fi
  done
}

confirm() { # word
  read -r -p "Type $1 to continue (anything else aborts): " answer
  [[ "${answer}" == "$1" ]] || { echo "aborted"; exit 1; }
}

case "${1:-}" in
  fmt)
    terraform -chdir="${TF}" fmt -recursive -check -diff
    ;;
  validate)
    for d in "${roots[@]}" "${modules[@]}"; do
      echo "== validate ${d#"${ROOT}/"}"
      terraform -chdir="${d}" init -backend=false -input=false -no-color >/dev/null
      terraform -chdir="${d}" validate -no-color
    done
    ;;
  lint)
    tflint --chdir="${TF}" --config="${TF}/.tflint.hcl" --init
    for d in "${roots[@]}" "${modules[@]}"; do
      echo "== tflint ${d#"${ROOT}/"}"
      tflint --chdir="${d}" --config="${TF}/.tflint.hcl" --format compact
    done
    ;;
  local)
    terraform -chdir="${TF}/envs/local" init -input=false
    terraform -chdir="${TF}/envs/local" apply -auto-approve -input=false
    ;;
  bootstrap-plan)
    need_aws_creds
    terraform -chdir="${TF}/bootstrap" init -input=false
    terraform -chdir="${TF}/bootstrap" plan -input=false
    ;;
  bootstrap-apply)
    need_aws_creds
    terraform -chdir="${TF}/bootstrap" init -input=false
    terraform -chdir="${TF}/bootstrap" plan -input=false -out=tfplan
    confirm APPLY
    terraform -chdir="${TF}/bootstrap" apply -input=false tfplan
    terraform -chdir="${TF}/bootstrap" output -raw backend_hcl > "${AWS_DIR}/backend.hcl"
    echo "wrote terraform/envs/aws/backend.hcl"
    ;;
  plan)
    need_aws_creds
    need_files
    terraform -chdir="${AWS_DIR}" init -input=false -backend-config=backend.hcl -reconfigure
    terraform -chdir="${AWS_DIR}" plan -input=false -out=tfplan
    terraform -chdir="${AWS_DIR}" show -json tfplan > "${REPORTS}/tfplan.json"
    if command -v infracost >/dev/null && [[ -n "${INFRACOST_API_KEY:-}" ]]; then
      infracost breakdown --path "${REPORTS}/tfplan.json" --format table | tee "${REPORTS}/infracost.txt"
    else
      echo "(infracost skipped: set INFRACOST_API_KEY to get a cost estimate)"
    fi
    echo "Plan saved to terraform/envs/aws/tfplan. Nothing was created."
    ;;
  apply)
    need_aws_creds
    [[ -f "${AWS_DIR}/tfplan" ]] || { echo "Run 'make aws-plan' first." >&2; exit 1; }
    echo "This creates BILLABLE resources (EKS ~USD 0.10/h + NAT ~0.045/h + nodes + EC2)."
    confirm APPLY
    terraform -chdir="${AWS_DIR}" apply -input=false tfplan
    ;;
  destroy)
    need_aws_creds
    need_files
    confirm DESTROY
    terraform -chdir="${AWS_DIR}" destroy -input=false
    ;;
  *)
    echo "usage: $0 {fmt|validate|lint|local|plan|apply|destroy|bootstrap-plan|bootstrap-apply}" >&2
    exit 2
    ;;
esac
