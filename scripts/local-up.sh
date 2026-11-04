#!/usr/bin/env bash
# LOCAL MODE bring-up (zero cost). Idempotent; safe to re-run.
#   1. .env with generated secrets      4. SonarQube + bootstrap (gate, webhook, token)
#   2. kind network + local registry     5. Jenkins image build + start (JCasC)
#   3. Cosign key pair
#   6. kind cluster add-ons + policies, kubeconfig for Jenkins
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export PATH="${ROOT}/.bin:${PATH}"
COMPOSE=(docker compose --env-file .env -f local/docker-compose.yml)

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "1/6 environment file"
python3 scripts/envfile.py init

step "2/6 kind cluster + local registry"
docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null
bash scripts/kind-up.sh
bash scripts/local-registry.sh up

step "3/6 cosign key pair"
bash scripts/cosign-keygen.sh

step "4/6 SonarQube"
"${COMPOSE[@]}" up -d --wait sonar-db sonarqube
bash scripts/sonar-bootstrap.sh

step "5/6 Jenkins (first build of the image takes several minutes)"
"${COMPOSE[@]}" up -d --build --wait jenkins
bash scripts/jenkins-kubeconfig.sh

step "6/6 cluster add-ons (Prometheus, Grafana, Pushgateway, Argo Rollouts, Kyverno, policies)"
bash scripts/cluster-addons.sh

ADMIN_USER="$(python3 scripts/envfile.py get JENKINS_ADMIN_USER)"
cat <<EOF

SentinelOps local stack is up
  Jenkins    http://localhost:8080   user: ${ADMIN_USER:-admin}   password: see JENKINS_ADMIN_PASSWORD in .env
  SonarQube  http://localhost:9000   user: admin                password: see SONAR_ADMIN_PASSWORD in .env
  Registry   localhost:5001
The "SentinelOps" multibranch job indexes GitHub every 2 minutes (or click "Scan Multibranch Pipeline Now").
EOF
