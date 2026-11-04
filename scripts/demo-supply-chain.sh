#!/usr/bin/env bash
# Feature 2 proof: the cluster REJECTS images that are unsigned, unscanned, untrusted or
# mutable, and ADMITS the image the pipeline signed. Uses server-side dry-run, so the
# admission webhooks run but nothing is created.
#   make demo-supply-chain
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
CTX="${KUBE_CONTEXT:-kind-sentinelops}"
K=(kubectl --context "${CTX}")
NS=sentinelops
PASS=0
FAILS=0

pod_yaml() { # name image
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $1, namespace: ${NS} }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: app
      image: $2
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources: { limits: { cpu: 100m, memory: 64Mi } }
EOF
}

expect() { # deny|allow description image
  local want="$1" desc="$2" image="$3" out rc
  set +e
  out="$(pod_yaml "demo-$RANDOM" "${image}" | "${K[@]}" apply --dry-run=server -f - 2>&1)"
  rc=$?
  set -e
  if [[ "${want}" == deny && ${rc} -ne 0 ]]; then
    echo "PASS  rejected  ${desc}"; echo "      ${out##*: }" | head -c 300; echo
    PASS=$((PASS + 1))
  elif [[ "${want}" == allow && ${rc} -eq 0 ]]; then
    echo "PASS  admitted  ${desc}"; PASS=$((PASS + 1))
  else
    echo "FAIL  expected ${want} for ${desc}: ${out}"; FAILS=$((FAILS + 1))
  fi
}

echo "1) building an UNSIGNED variant of the app image (different digest, never signed)"
docker build -q -f "${ROOT}/docker/Dockerfile" --label "sentinelops.demo=unsigned-$(date +%s)" \
  -t localhost:5001/sentinelops-app:unsigned-demo "${ROOT}/app" >/dev/null
docker push -q localhost:5001/sentinelops-app:unsigned-demo >/dev/null
UNSIGNED_DIGEST="$(docker image inspect localhost:5001/sentinelops-app:unsigned-demo \
  --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep '^localhost:5001/sentinelops-app@' | head -n1 | cut -d@ -f2)"
echo

echo "2) admission checks (server-side dry-run)"
expect deny "unsigned image from the trusted registry" "kind-registry:5000/sentinelops-app@${UNSIGNED_DIGEST}"
expect deny "mutable tag (:unsigned-demo)" "kind-registry:5000/sentinelops-app:unsigned-demo"
expect deny "untrusted public image (nginx:latest)" "docker.io/library/nginx:latest"

SIGNED="$("${K[@]}" -n "${NS}" get rollout sentinelops-app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ -n "${SIGNED}" ]]; then
  expect allow "pipeline-signed image currently deployed (${SIGNED##*@})" "${SIGNED}"
else
  echo "SKIP  no deployed rollout yet - run the Jenkins pipeline once to test the signed path"
fi

echo
echo "result: ${PASS} passed, ${FAILS} failed"
[[ ${FAILS} -eq 0 ]]
