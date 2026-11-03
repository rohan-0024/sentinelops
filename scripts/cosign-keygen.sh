#!/usr/bin/env bash
# Generates the Cosign key pair used to sign images (Feature 2).
#   private key -> local/secrets/cosign.key (git-ignored) + COSIGN_KEY_B64 in .env
#   public key  -> policy/keys/cosign.pub (Kyverno verifies signatures with it)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVPY="python3 ${ROOT}/scripts/envfile.py"
SECRETS="${ROOT}/local/secrets"
PUB="${ROOT}/policy/keys/cosign.pub"
COSIGN="${ROOT}/.bin/cosign"
[[ -x "${COSIGN}" ]] || COSIGN="$(command -v cosign || true)"
[[ -n "${COSIGN}" ]] || { echo "cosign not found - run make tools" >&2; exit 1; }

if [[ -f "${SECRETS}/cosign.key" && -f "${PUB}" && "$(${ENVPY} get COSIGN_KEY_B64)" != "" ]]; then
  echo "cosign key pair already exists (${PUB})"
  exit 0
fi

COSIGN_PASSWORD="$(${ENVPY} get COSIGN_PASSWORD)"
[[ -n "${COSIGN_PASSWORD}" ]] || { echo "COSIGN_PASSWORD missing in .env (run make init-env)" >&2; exit 1; }
export COSIGN_PASSWORD

mkdir -p "${SECRETS}" "$(dirname "${PUB}")"
chmod 700 "${SECRETS}"
(cd "${SECRETS}" && rm -f cosign.key cosign.pub && "${COSIGN}" generate-key-pair >/dev/null)
mv "${SECRETS}/cosign.pub" "${PUB}"
chmod 600 "${SECRETS}/cosign.key"
${ENVPY} set COSIGN_KEY_B64 "$(base64 -w0 < "${SECRETS}/cosign.key")"
echo "cosign key pair created: private in local/secrets/ (git-ignored), public at policy/keys/cosign.pub"
