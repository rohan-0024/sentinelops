# Ubuntu 22.04 test image for Molecule (matches the EC2 AMI release).
# No systemd: systemd as PID 1 exits immediately under WSL2 + Docker Desktop, so
# services are installed but started directly in verify.yml instead.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-apt sudo ca-certificates openssh-server curl gnupg procps \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash ubuntu
CMD ["sleep", "infinity"]
