#!/usr/bin/env bash
# Idempotent SonarQube setup for the pipeline:
#   1. replace the default admin/admin password with SONAR_ADMIN_PASSWORD
#   2. create the "SentinelOps Gate" quality gate (overall code) and make it default
#   3. register the Jenkins webhook (needed by waitForQualityGate)
#   4. create a global analysis token for Jenkins and store it in .env as SONAR_TOKEN
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVPY="python3 ${ROOT}/scripts/envfile.py"
SONAR="${SONAR_URL:-http://localhost:9000}"
JENKINS_WEBHOOK="${JENKINS_WEBHOOK:-http://jenkins:8080/sonarqube-webhook/}"
GATE="SentinelOps Gate"
ADMIN_PW="$(${ENVPY} get SONAR_ADMIN_PASSWORD)"
[[ -n "${ADMIN_PW}" ]] || { echo "SONAR_ADMIN_PASSWORD missing in .env (run make init-env)" >&2; exit 1; }

echo "waiting for SonarQube at ${SONAR} ..."
for _ in $(seq 1 90); do
  curl -fsS "${SONAR}/api/system/status" 2>/dev/null | grep -q '"status":"UP"' && break
  sleep 5
done
curl -fsS "${SONAR}/api/system/status" | grep -q '"status":"UP"' || { echo "SonarQube did not come up" >&2; exit 1; }

api() { # method path [curl args...]
  local method="$1" path="$2"; shift 2
  curl -fsS -u "admin:${ADMIN_PW}" -X "${method}" "${SONAR}${path}" "$@"
}

# 1. admin password
if ! curl -fsS -u "admin:${ADMIN_PW}" "${SONAR}/api/authentication/validate" | grep -q '"valid":true'; then
  echo "changing default admin password"
  curl -fsS -u admin:admin -X POST "${SONAR}/api/users/change_password" \
    --data-urlencode "login=admin" --data-urlencode "previousPassword=admin" \
    --data-urlencode "password=${ADMIN_PW}" >/dev/null
fi
curl -fsS -u "admin:${ADMIN_PW}" "${SONAR}/api/authentication/validate" | grep -q '"valid":true' \
  || { echo "cannot authenticate as admin" >&2; exit 1; }

# 2. quality gate on overall code (first analyses have no "new code" period)
if ! api GET "/api/qualitygates/show" --get --data-urlencode "name=${GATE}" >/dev/null 2>&1; then
  echo "creating quality gate '${GATE}'"
  api POST /api/qualitygates/create --data-urlencode "name=${GATE}" >/dev/null
  cond() { api POST /api/qualitygates/create_condition --data-urlencode "gateName=${GATE}" \
             --data-urlencode "metric=$1" --data-urlencode "op=$2" --data-urlencode "error=$3" >/dev/null; }
  cond coverage LT 80             # coverage below 80 %
  cond security_rating GT 1       # worse than A
  cond reliability_rating GT 1    # worse than A
  cond vulnerabilities GT 0       # any vulnerability
fi
api POST /api/qualitygates/set_as_default --data-urlencode "name=${GATE}" >/dev/null

# 3. webhook to Jenkins
if ! api GET /api/webhooks/list | grep -q "${JENKINS_WEBHOOK}"; then
  echo "registering Jenkins webhook ${JENKINS_WEBHOOK}"
  api POST /api/webhooks/create --data-urlencode "name=jenkins" --data-urlencode "url=${JENKINS_WEBHOOK}" >/dev/null
fi

# 4. analysis token for Jenkins
token="$(${ENVPY} get SONAR_TOKEN)"
if [[ -n "${token}" && "${token}" != "unset" ]] \
   && curl -fsS -u "${token}:" "${SONAR}/api/authentication/validate" | grep -q '"valid":true'; then
  echo "existing SONAR_TOKEN is valid"
else
  api POST /api/user_tokens/revoke --data-urlencode "name=jenkins" >/dev/null 2>&1 || true
  token="$(api POST /api/user_tokens/generate --data-urlencode "name=jenkins" \
            --data-urlencode "type=GLOBAL_ANALYSIS_TOKEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  ${ENVPY} set SONAR_TOKEN "${token}"
  echo "generated SONAR_TOKEN and saved it to .env"
fi
echo "SonarQube bootstrap complete (gate: ${GATE})"
