# CLAUDE.md — SentinelOps conventions

Project: **SentinelOps** — a self-defending, cost-aware DevSecOps platform.
Academic title: *Secure CI/CD Pipeline for Containerized Applications with AWS*.
Flow: GitHub → Jenkins → SonarQube → Trivy → Docker → ECR → EKS, monitored by
Prometheus + Grafana, provisioned by Terraform, configured by Ansible.

## Golden rules
1. **Never run `terraform apply`** (or any command that creates billable AWS
   resources) without explicit confirmation from the owner. `make aws-plan` only.
2. **No secrets in git.** Use `.env` (git-ignored, copied from `.env.example`),
   Jenkins credentials, Kubernetes Secrets, or AWS Secrets Manager. gitleaks runs
   in CI and in `make verify`.
3. **Pin every version.** Tool versions live in `versions.env`; Python deps in
   `requirements*.txt` with `==`; Helm charts and container images by exact tag.
4. **Do not fake output.** If something needs real AWS credentials or the owner's
   laptop, say so and give the exact command.
5. **One codebase, two modes:** `MODE=local` (default, kind + Compose, zero cost)
   and `MODE=aws` (Terraform → EKS/ECR). Mode differences live in config/values
   files, never in forked code.

## Execution environment
- Owner's machine: **Windows + Docker Desktop (WSL2 backend), 16 GB RAM**.
  All `make` targets and scripts run inside **WSL2 Ubuntu**, from a clone in the
  Linux filesystem (`~/sentinelops`, not `/mnt/c/...` — bind mounts and file
  watching are slow/broken across the Windows boundary).
- AWS account: **AWS Academy Learner Lab** → cannot create IAM roles/OIDC
  providers. Terraform uses `lab_mode = true` to reuse the existing `LabRole`.
  `lab_mode = false` enables full IAM + IRSA for a standard account.

## Repository layout
| Path | Purpose |
|---|---|
| `app/` | FastAPI microservice (`/health`, `/ready`, `/metrics`) + pytest suite |
| `docker/` | Multi-stage, non-root, distroless Dockerfile |
| `terraform/` | Modules: vpc, eks, ecr, iam, jenkins-ec2, state-backend, finops; `envs/aws` root |
| `ansible/` | Roles: docker, jenkins, sonarqube, trivy, node-exporter, hardening |
| `k8s/` | Helm chart (Argo Rollout), Kyverno policies, cluster add-on values |
| `jenkins/` | Jenkinsfile, shared library, JCasC, custom Jenkins image |
| `monitoring/` | Prometheus rules, Alertmanager config, Grafana dashboards (JSON) |
| `policy/` | `risk.yaml` (DRS weights), Rego, Kyverno sources |
| `tools/` | Python CLIs: `drs`, `explain`, `finops`, `chaos` |
| `scripts/` | Bash glue invoked by Makefile targets |
| `docs/` | Architecture, runbook, threat model, cost report, viva Q&A, demo |

## Conventions
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `ci:`,
  `chore:`, `refactor:`), one commit per phase minimum.
- **Python:** 3.11 (matches distroless runtime). Format/lint with `ruff`.
  Tests with `pytest`; app coverage gate ≥ 80 %. Each tool in `tools/` has tests.
- **Shell:** `#!/usr/bin/env bash` + `set -euo pipefail`; lint with shellcheck.
- **YAML:** 2-space indent, yamllint config in `.yamllint`.
- **Terraform:** every resource tagged via `default_tags`
  (`Project=sentinelops`, `Owner`, `Environment`, `ManagedBy=terraform`,
  `AutoTeardown=true`); small instance types; must pass `terraform validate`,
  `tflint`, `checkov` (documented skips only, with justification inline).
- **Images:** named `sentinelops-app:<git-sha>`; never deploy `:latest`.
- **Ports (local mode):** Jenkins 8080, SonarQube 9000, registry 5001,
  LocalStack 4566, app 30080, Grafana 30300, Prometheus 30090,
  Pushgateway 30091, Alertmanager 30093, Argo Rollouts dashboard 3100.

## Verification
`make verify` = lint + unit tests + coverage + IaC scans + policy tests + tool
tests. Phase status and what was verified where is tracked in
`docs/PROGRESS.md`.
