# Systemd-enabled Ubuntu 22.04 image for Molecule (matches the EC2 AMI release).
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv python3 python3-apt sudo ca-certificates openssh-server curl \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash ubuntu \
 && rm -f /lib/systemd/system/multi-user.target.wants/* /etc/systemd/system/*.wants/* \
      /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
      /lib/systemd/system/systemd-update-utmp*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
