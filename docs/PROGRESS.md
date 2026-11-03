# Progress log

Legend: **here** = verified in the build workspace · **laptop** = must be verified by
the owner in WSL2 (command given) · **aws** = needs AWS Academy credentials.

| Phase | Status | Verified here | Owner must run |
|---|---|---|---|
| 0 Plan & conventions | done | files, `make help` | — |
| 1 App + tests + Dockerfile + registry | **verified on laptop** | 18 tests, 98.9 % coverage, ruff, checkov Dockerfile 63/63 | done: `make image-test` → SMOKE OK |
| 2 Terraform | **verified on laptop** (`make verify` incl. tf-check, `make tf-local`) | checkov 203 passed / 0 failed / 28 justified skips; finops handler 8 tests (moto); shellcheck | `make tools && make tf-check && make tf-local`; AWS: `make aws-plan` |
| 3 Ansible | **verified on laptop** (`make ansible-test`: converge, idempotence 0 changed, verify 11/11) | ansible-lint production profile 0 failures (38 files), yamllint, syntax-check | `make ansible-test` (Molecule); AWS: `make ansible-aws` |
| 4 Jenkins + SonarQube + Trivy | done | Groovy parse (npm-groovy-lint, 0 errors), checkov Jenkins Dockerfile, shellcheck, yamllint, ansible-lint, compose config, envfile tests | `make local-up`, then run the SentinelOps job |
| 5 Kubernetes/Helm + Kyverno + Argo Rollouts | pending | | |
| 6 Monitoring | pending | | |
| 7 Unique features 1–6 | pending | | |
| 8 `make verify` + attack/fix demo | pending | | |
| 9 Docs | pending | | |

## Why some checks can't run in the build workspace
The workspace's network allowlist blocks Docker Hub, gcr.io, ghcr.io, quay.io,
registry.k8s.io, releases.hashicorp.com, get.helm.sh and GitHub release downloads.
So image builds, kind, terraform, tflint, helm, trivy, cosign and gitleaks are
verified on the owner's laptop. pip-installable tools (pytest, ruff, checkov,
yamllint, ansible-lint, moto) are verified here.

## Phase 2 notes
- EKS pinned to **1.35** (standard support until 2027-03-27). 1.34 leaves standard
  support on 2026-12-02 and would bill extended support (6x control-plane price).
- `lab_mode = true` (default) reuses AWS Academy `LabRole` / `LabInstanceProfile`;
  IRSA and the `iam` module are only used with `lab_mode = false`.
- In lab mode Jenkins deploys to EKS with a ServiceAccount kubeconfig (Phase 4),
  because LabRole is already bound to the node group's access entry.
- Node volumes use the AWS-managed EBS key (a CMK would need a key-policy grant
  for the AutoScaling service-linked role, which may not exist in a fresh account).
- FinOps Lambda reserved concurrency defaults to unreserved (-1): Learner Lab
  accounts have a concurrency limit of 10.
- `terraform validate` / `tflint` could not run in the build workspace
  (registry.terraform.io and GitHub releases are blocked); they run on the laptop
  via `make tf-check`.

## Phase 3 notes
- Role `node-exporter` from the brief is named `node_exporter` (Ansible role names
  must be `[a-z0-9_]`).
- Molecule converges hardening, docker, node_exporter and trivy in an Ubuntu
  22.04 container, checks idempotence, then verifies (sshd hardening, pinned +
  held docker-ce, node_exporter unit installed and serving metrics on :9100,
  Trivy 0.69.3). systemd as PID 1 exits immediately under WSL2 + Docker Desktop
  (verified on the owner's laptop: exit 255), so the test container has no
  systemd: services are installed but node_exporter is started directly in
  verify. Firewall, sysctl, nested dockerd and the Trivy DB download are
  disabled in the container; on EC2 they all run normally.
- `jenkins` and `sonarqube` roles run the same container images as local mode;
  they are lint/syntax-checked here and exercised end-to-end on the EC2 host.
- Secrets (JENKINS_ADMIN_PASSWORD, SONAR_DB_PASSWORD) are read from the
  controller's environment / `.env`, never stored in the repo; tasks use no_log.
- Jenkins SG now allows 9100 from the VPC CIDR so Prometheus on EKS can scrape
  the CI host.

## Phase 4 notes
- Jenkins **2.580.2 LTS (Java 21)**: current LTS on 2026-10-28; older LTS lines
  have published CVEs and newer plugins no longer support them.
- One image for both modes: plugins resolved against the core's update center
  (resolved set saved as `plugins.lock.txt` in the image), JCasC for security
  realm, credentials, SonarQube server, shared library and a multibranch job
  (`main` + `demo/*`, indexed every 2 min).
- The Jenkins container mounts the Docker socket, which is root-equivalent on the
  host. It is accepted for a single-user lab and recorded in the threat model;
  production would use rootless BuildKit or Kaniko agents.
- SonarQube Community has no branch analysis, so non-main branches use their own
  project key (`sentinelops-app-<branch>`). The quality gate "SentinelOps Gate"
  uses overall-code conditions (coverage >= 80, security/reliability rating A,
  0 vulnerabilities), because first analyses have no "new code" period.
- Trivy gate: fail on CRITICAL **with an available fix**. Unfixable CVEs are
  reported and weighted by the DRS (Phase 7); accepted CVEs go in `.trivyignore`.
- Signing: Cosign key pair (`make cosign-keygen`), image signed by digest plus two
  attestations (CycloneDX SBOM and Trivy `cosign-vuln`) so Kyverno can reject
  unsigned *and* unscanned images in Phase 5. `--tlog-upload=false` because the
  registry is private.
- Stages 8, 11 and 12 are guarded by `when { fileExists(...) }` and show as
  *skipped* until Phases 5 and 7 add their scripts.
- Groovy is syntax-checked here with npm-groovy-lint. Declarative-pipeline
  semantics can only be validated by a running Jenkins (owner's laptop).
