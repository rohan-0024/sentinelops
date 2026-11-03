#!/usr/bin/env bash
# Grants the jenkins user access to the mounted Docker socket, then drops root.
# The socket's group id differs between hosts (Docker Desktop, Ubuntu EC2), so it
# is detected at start-up instead of being baked into the image.
set -euo pipefail

SOCK=/var/run/docker.sock
if [[ -S "${SOCK}" ]]; then
  gid="$(stat -c '%g' "${SOCK}")"
  if [[ "${gid}" == "0" ]]; then
    # Docker Desktop exposes the socket as root:root; allow group access via a
    # dedicated group instead of adding jenkins to the root group.
    groupadd -f dockersock
    chgrp dockersock "${SOCK}"
    chmod g+rw "${SOCK}"
    group=dockersock
  else
    group="$(getent group "${gid}" | cut -d: -f1 || true)"
    if [[ -z "${group}" ]]; then
      groupadd -g "${gid}" dockersock
      group=dockersock
    fi
  fi
  usermod -aG "${group}" jenkins
fi

chown jenkins:jenkins /var/cache/trivy 2>/dev/null || true

exec setpriv --reuid=jenkins --regid=jenkins --init-groups /usr/local/bin/jenkins.sh "$@"
