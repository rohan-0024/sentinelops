# Screenshot checklist

Save as `docs/screenshots/<nn>-<name>.png`, e.g. `06-pipeline-green.png`. Capture full browser
width, at 100 % zoom or more, with the URL bar visible. ☐ = to do.

## Setup and code quality
| # | Figure | How to get it | ☐ |
|---|---|---|---|
| 01 | `make verify` ending in `verify: OK` | WSL terminal | ☐ |
| 02 | App tests + coverage table (98.9 %) | top of `make verify` output | ☐ |
| 03 | `make local-up` summary (service URLs) | WSL terminal | ☐ |
| 04 | GitHub Actions `verify` run green | github.com/rohan-0024/sentinelops/actions | ☐ |
| 05 | SonarQube project dashboard, quality gate **Passed** | http://localhost:9000 | ☐ |

## Pipeline
| # | Figure | How | ☐ |
|---|---|---|---|
| 06 | Jenkins stage view, all 13 stages green | Jenkins → sentinelops → main | ☐ |
| 07 | Stage 8 log: DRS table and decision | build → Console → search "Deployment Risk Score" | ☐ |
| 08 | `drs.md` artifact | build → Build Artifacts | ☐ |
| 09 | Stage 6 Trivy summary + gate line | Console, search "Trivy:" | ☐ |
| 10 | Stage 10 "signed + attested (SBOM, vulnerability scan, SLSA provenance)" | Console | ☐ |
| 11 | `make provenance-check` all OK | terminal | ☐ |
| 12 | Stage 12: chaos JSON + `CHAOS GATE PASSED` | Console | ☐ |
| 13 | Failed build #24 (gitleaks) stage view + `explain.md` | Jenkins build #24 | ☐ |

## Kubernetes and progressive delivery
| # | Figure | How | ☐ |
|---|---|---|---|
| 14 | `make rollout-status`: Healthy, AnalysisRun Successful | terminal | ☐ |
| 15 | Argo Rollouts dashboard during a canary (10 % step) | `make rollouts-dashboard` → :3100 | ☐ |
| 16 | `make demo-canary`: Degraded / RolloutAborted, AnalysisRun 7 ✔ 3 ✖ | terminal | ☐ |
| 17 | `make demo-supply-chain` 4 passed | terminal | ☐ |
| 18 | `kubectl get pods -A` (all add-ons Running) | terminal | ☐ |

## Security demo
| # | Figure | How | ☐ |
|---|---|---|---|
| 19 | `make demo-attack` scoreboard, 6 × PASS | terminal | ☐ |
| 20 | `reports/demo/scoreboard.md` rendered (VS Code preview) | editor | ☐ |
| 21 | Jenkins `demo/vulnerable` red at stage 6 + its `explain.md` | `make demo-branch`, Scan Multibranch | ☐ |
| 22 | `make demo-fix` 5 × PASS | terminal | ☐ |

## Monitoring
| # | Figure | How | ☐ |
|---|---|---|---|
| 23 | Grafana **DevSecOps Command Center**, full page | :30300 → Dashboards → SentinelOps | ☐ |
| 24 | Service SLO dashboard (error budget, burn rate) | same folder | ☐ |
| 25 | Delivery dashboard (DORA) | same folder | ☐ |
| 26 | Cluster health dashboard | same folder | ☐ |
| 27 | Prometheus → Alerts page, SentinelOps rule groups | :30090/alerts | ☐ |
| 28 | Telegram / Slack notification with "Why:" line (if configured) | phone or Slack | ☐ |

## Infrastructure as code
| # | Figure | How | ☐ |
|---|---|---|---|
| 29 | `make tf-check` validate + tflint clean | terminal | ☐ |
| 30 | checkov summary (terraform 203 passed / 0 failed) | `make iac-scan` | ☐ |
| 31 | `make ansible-test` idempotence 0 changed + verify | terminal | ☐ |
| 32 | `make tf-local` (LocalStack apply of state-backend + finops) | terminal | ☐ |
| 33 | **AWS:** `make aws-plan` summary "Plan: N to add" | terminal with Learner Lab creds | ☐ |
| 34 | **AWS (optional, billable):** EKS console + nodes, ECR repo with signed image | AWS console | ☐ |
| 35 | **AWS:** `make aws-destroy` completed | terminal | ☐ |

> Before sharing, check that no screenshot shows a password, token, AWS key or `.env` content.
