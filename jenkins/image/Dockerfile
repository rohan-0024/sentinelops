# syntax=docker/dockerfile:1.7
# SentinelOps Jenkins controller: LTS + pinned plugins + JCasC + every CI CLI the
# Jenkinsfile needs. Same image in local mode (Compose) and AWS mode (Ansible).
# Build context: repository root
#   docker build -f jenkins/image/Dockerfile -t sentinelops-jenkins:local .
# Keep the tag in sync with JENKINS_IMAGE in versions.env.
FROM jenkins/jenkins:2.580.2-lts-jdk21
# checkov:skip=CKV_DOCKER_8:Entrypoint starts as root only to grant docker-socket group access, then drops to jenkins via setpriv

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- OS packages: python for tests/tools, jq for report parsing ---
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-pip git curl unzip jq make ca-certificates util-linux \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY versions.env /opt/sentinelops/versions.env
COPY scripts/install-tools.sh /opt/sentinelops/scripts/install-tools.sh

# --- Docker CLI + buildx (talk to the host daemon via the mounted socket) ---
RUN source /opt/sentinelops/versions.env \
 && ARCH="$(uname -m)"; BX_ARCH=$([[ ${ARCH} == x86_64 ]] && echo amd64 || echo arm64) \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
    | tar -xz -C /usr/local/bin --strip-components=1 docker/docker \
 && mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
    "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BX_ARCH}" \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx \
 && docker --version && docker buildx version

# --- kubectl, helm, terraform, trivy, syft, cosign, gitleaks, kyverno, rollouts, conftest, infracost ---
RUN BIN=/usr/local/bin \
    TOOLS="kubectl helm terraform trivy syft cosign gitleaks kyverno kubectl-argo-rollouts conftest infracost" \
    bash /opt/sentinelops/scripts/install-tools.sh \
 && rm -f /usr/local/bin/.*.version

# --- sonar-scanner CLI (bundled JRE) ---
RUN source /opt/sentinelops/versions.env \
 && curl -fsSL -o /tmp/ss.zip \
    "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" \
 && unzip -q /tmp/ss.zip -d /opt && rm /tmp/ss.zip \
 && ln -s "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64/bin/sonar-scanner" /usr/local/bin/sonar-scanner

# --- AWS CLI v2 (ECR login, EKS kubeconfig in AWS mode) ---
RUN source /opt/sentinelops/versions.env \
 && curl -fsSL -o /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m)-${AWSCLI_VERSION}.zip" \
 && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip \
 && aws --version

# --- Python tooling for scans and the SentinelOps CLIs (checkov, DRS, explainer) ---
COPY jenkins/image/requirements-ci.txt /opt/sentinelops/requirements-ci.txt
RUN python3 -m venv /opt/ci-venv \
 && /opt/ci-venv/bin/pip install --no-cache-dir -q -r /opt/sentinelops/requirements-ci.txt
ENV PATH="/opt/ci-venv/bin:${PATH}"

# --- Plugins (resolved against this core's update center) + JCasC ---
COPY jenkins/image/plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --verbose \
 && jenkins-plugin-cli --list > /usr/share/jenkins/ref/plugins.lock.txt
COPY jenkins/image/casc/ /usr/share/jenkins/casc/
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc \
    JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=false" \
    TRIVY_CACHE_DIR=/var/cache/trivy

RUN mkdir -p /var/cache/trivy && chown jenkins:jenkins /var/cache/trivy
COPY jenkins/image/entrypoint.sh /usr/local/bin/sentinel-entrypoint.sh
RUN chmod 0755 /usr/local/bin/sentinel-entrypoint.sh

# Starts as root only to grant the docker-socket group, then drops to the jenkins user.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=5 \
  CMD curl -fsS http://localhost:8080/login > /dev/null || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/sentinel-entrypoint.sh"]
