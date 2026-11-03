# Progress log

Legend: **here** = verified in the build workspace · **laptop** = must be verified by
the owner in WSL2 (command given) · **aws** = needs AWS Academy credentials.

| Phase | Status | Verified here | Owner must run |
|---|---|---|---|
| 0 Plan & conventions | done | files, `make help` | — |
| 1 App + tests + Dockerfile + registry | done | 18 tests, 98.9 % coverage, ruff, checkov Dockerfile 63/63 | `make tools && make image-test && make push-local` |
| 2 Terraform | pending | | |
| 3 Ansible | pending | | |
| 4 Jenkins + SonarQube + Trivy | pending | | |
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
