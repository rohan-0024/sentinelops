#!/usr/bin/env bash
# Installs pinned CLI tools into ./.bin (Linux/WSL2 x86_64 or arm64).
# Idempotent: skips tools whose pinned version is already present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"
BIN="${ROOT}/.bin"
mkdir -p "${BIN}"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
OS=linux
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

have() { [[ -x "${BIN}/$1" ]] && [[ -f "${BIN}/.$1.version" ]] && [[ "$(cat "${BIN}/.$1.version")" == "$2" ]]; }
mark() { echo "$2" > "${BIN}/.$1.version"; echo "  installed $1 $2"; }
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

install_raw() { # name version url
  have "$1" "$2" && return 0
  fetch "$3" "${BIN}/$1"; chmod +x "${BIN}/$1"; mark "$1" "$2"
}
install_tgz() { # name version url path-in-archive
  have "$1" "$2" && return 0
  fetch "$3" "${TMP}/$1.tgz"; tar -xzf "${TMP}/$1.tgz" -C "${TMP}"
  install -m 0755 "${TMP}/$4" "${BIN}/$1"; mark "$1" "$2"
}
install_zip() { # name version url path-in-archive
  have "$1" "$2" && return 0
  fetch "$3" "${TMP}/$1.zip"; (cd "${TMP}" && unzip -oq "$1.zip")
  install -m 0755 "${TMP}/$4" "${BIN}/$1"; mark "$1" "$2"
}

echo "Installing pinned tools into ${BIN}"
install_raw kind "${KIND_VERSION}" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
install_raw kubectl "${KUBECTL_VERSION}" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
install_tgz helm "${HELM_VERSION}" "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" "${OS}-${ARCH}/helm"
install_zip terraform "${TERRAFORM_VERSION}" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip" "terraform"
install_zip tflint "${TFLINT_VERSION}" "https://github.com/terraform-linters/tflint/releases/download/${TFLINT_VERSION}/tflint_${OS}_${ARCH}.zip" "tflint"
TRIVY_ARCH=$([[ ${ARCH} == amd64 ]] && echo 64bit || echo ARM64)
install_tgz trivy "${TRIVY_VERSION}" "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz" "trivy"
install_tgz syft "${SYFT_VERSION}" "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${OS}_${ARCH}.tar.gz" "syft"
install_raw cosign "${COSIGN_VERSION}" "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-${OS}-${ARCH}"
GL_ARCH=$([[ ${ARCH} == amd64 ]] && echo x64 || echo arm64)
install_tgz gitleaks "${GITLEAKS_VERSION}" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${OS}_${GL_ARCH}.tar.gz" "gitleaks"
KY_ARCH=$([[ ${ARCH} == amd64 ]] && echo x86_64 || echo arm64)
install_tgz kyverno "${KYVERNO_CLI_VERSION}" "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_CLI_VERSION}/kyverno-cli_${KYVERNO_CLI_VERSION}_${OS}_${KY_ARCH}.tar.gz" "kyverno"
install_raw kubectl-argo-rollouts "${KUBECTL_ARGO_ROLLOUTS_VERSION}" "https://github.com/argoproj/argo-rollouts/releases/download/${KUBECTL_ARGO_ROLLOUTS_VERSION}/kubectl-argo-rollouts-${OS}-${ARCH}"
CT_ARCH=$([[ ${ARCH} == amd64 ]] && echo x86_64 || echo arm64)
install_tgz conftest "${CONFTEST_VERSION}" "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${CT_ARCH}.tar.gz" "conftest"
install_tgz infracost "${INFRACOST_VERSION}" "https://github.com/infracost/infracost/releases/download/${INFRACOST_VERSION}/infracost-${OS}-${ARCH}.tar.gz" "infracost-${OS}-${ARCH}"
echo "Done. Add to PATH:  export PATH=\"${BIN}:\$PATH\"  (the Makefile does this automatically)"
