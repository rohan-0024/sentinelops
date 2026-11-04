#!/usr/bin/env bash
# Verifies, from the laptop, everything the pipeline attached to the image that is running:
# Cosign signature, CycloneDX SBOM, Trivy vulnerability scan and SLSA v1 provenance.
#   make provenance-check            (deployed image)
#   make provenance-check IMAGE=localhost:5001/sentinelops-app@sha256:...
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
PUB="${ROOT}/policy/keys/cosign.pub"
IMAGE="${IMAGE:-}"
if [[ -z "${IMAGE}" ]]; then
  IMAGE="$(kubectl --context "${KUBE_CONTEXT:-kind-sentinelops}" -n sentinelops get rollout sentinelops-app \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
fi
# Inside the cluster the registry is kind-registry:5000; from the laptop it is localhost:5001.
IMAGE="${IMAGE/kind-registry:5000/localhost:5001}"
FLAGS=(--key "${PUB}" --insecure-ignore-tlog=true --allow-insecure-registry --allow-http-registry)
echo "image: ${IMAGE}"

if cosign verify "${FLAGS[@]}" "${IMAGE}" >/dev/null 2>&1; then
  echo "  OK  signature"
else
  echo "  FAIL signature (not signed by ${PUB})"
  exit 1
fi
FAILS=0
for type in cyclonedx vuln slsaprovenance1; do
  if out="$(cosign verify-attestation "${FLAGS[@]}" --type "${type}" "${IMAGE}" 2>/dev/null)"; then
    printf '%s\n' "${out}" | python3 -c '
import base64, json, sys
t = sys.argv[1]
for line in sys.stdin:
    if not line.strip():
        continue
    st = json.loads(base64.b64decode(json.loads(line)["payload"]))
    p = st.get("predicate", {})
    if t == "slsaprovenance1":
        bd, rd = p["buildDefinition"], p["runDetails"]
        src = bd["resolvedDependencies"][0] if bd["resolvedDependencies"] else {}
        commit = src.get("digest", {}).get("gitCommit", "?")
        print("  OK  %-16s builder=%s" % (t, rd["builder"]["id"]))
        print("      source=%s commit=%s" % (src.get("uri", "?"), commit))
        print("      build=%s drs=%s" % (rd["metadata"].get("invocationId"), bd["internalParameters"].get("drsDecision")))
    else:
        print("  OK  %-16s predicateType=%s" % (t, st.get("predicateType")))
    break
' "${type}"
  else
    echo "  FAIL ${type} attestation missing or not signed by ${PUB}"
    FAILS=$((FAILS + 1))
  fi
done
[[ ${FAILS} -eq 0 ]]
