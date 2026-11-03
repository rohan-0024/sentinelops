#!/usr/bin/env bash
# Installs pinned CLI tools (Linux x86_64/arm64). Idempotent.
#   BIN=<dir>     install directory (default ./.bin)
#   TOOLS="a b"   subset to install (default: all)
# Used by `make tools` on the laptop and by jenkins/image/Dockerfile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"
BIN="${BIN:-${ROOT}/.bin}"
ALL_TOOLS="kind kubectl helm terraform tflint trivy syft cosign gitleaks kyverno kubectl-argo-rollouts conftest infracost"
TOOLS="${TOOLS:-${ALL_TOOLS}}"
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
fetch() { curl -fsSL --retry 3 -o "$2" "$1" || { echo "download failed: $1" >&2; return 1; }; }

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

pick() { [[ $1 == amd64 ]] && echo "$2" || echo "$3"; }
GH=https://github.com

install_one() {
  case "$1" in
    kind) install_raw kind "${KIND_VERSION}" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" ;;
    kubectl) install_raw kubectl "${KUBECTL_VERSION}" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" ;;
    helm) install_tgz helm "${HELM_VERSION}" "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" "${OS}-${ARCH}/helm" ;;
    terraform) install_zip terraform "${TERRAFORM_VERSION}" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip" terraform ;;
    tflint) install_zip tflint "${TFLINT_VERSION}" "${GH}/terraform-linters/tflint/releases/download/${TFLINT_VERSION}/tflint_${OS}_${ARCH}.zip" tflint ;;
    trivy) install_tgz trivy "${TRIVY_VERSION}" "${GH}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-$(pick "${ARCH}" 64bit ARM64).tar.gz" trivy ;;
    syft) install_tgz syft "${SYFT_VERSION}" "${GH}/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${OS}_${ARCH}.tar.gz" syft ;;
    cosign) install_raw cosign "${COSIGN_VERSION}" "${GH}/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-${OS}-${ARCH}" ;;
    gitleaks) install_tgz gitleaks "${GITLEAKS_VERSION}" "${GH}/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${OS}_$(pick "${ARCH}" x64 arm64).tar.gz" gitleaks ;;
    kyverno) install_tgz kyverno "${KYVERNO_CLI_VERSION}" "${GH}/kyverno/kyverno/releases/download/${KYVERNO_CLI_VERSION}/kyverno-cli_${KYVERNO_CLI_VERSION}_${OS}_$(pick "${ARCH}" x86_64 arm64).tar.gz" kyverno ;;
    kubectl-argo-rollouts) install_raw kubectl-argo-rollouts "${KUBECTL_ARGO_ROLLOUTS_VERSION}" "${GH}/argoproj/argo-rollouts/releases/download/${KUBECTL_ARGO_ROLLOUTS_VERSION}/kubectl-argo-rollouts-${OS}-${ARCH}" ;;
    conftest) install_tgz conftest "${CONFTEST_VERSION}" "${GH}/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_$(pick "${ARCH}" x86_64 arm64).tar.gz" conftest ;;
    infracost) install_tgz infracost "${INFRACOST_VERSION}" "${GH}/infracost/infracost/releases/download/${INFRACOST_VERSION}/infracost-${OS}-${ARCH}.tar.gz" "infracost-${OS}-${ARCH}" ;;
    *) echo "unknown tool: $1" >&2; return 1 ;;
  esac
}

echo "Installing pinned tools into ${BIN}"
failed=()
for t in ${TOOLS}; do
  install_one "${t}" || failed+=("${t}")
done
if ((${#failed[@]})); then
  echo "FAILED: ${failed[*]} (check versions.env and the release pages)" >&2
  exit 1
fi
echo "Done."
