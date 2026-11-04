# SentinelOps live demo (≈ 10 minutes)

The story is simple: **an attacker (or a careless developer) tries five ways to ship something
dangerous, and every gate stops it, then a bad release slips through review and the platform heals
itself.** Every check runs the real tool against the real cluster, and nothing is mocked.

## Before the audience arrives (T-15 min)
```bash
cd ~/sentinelops
make local-up            # Jenkins, SonarQube, kind, add-ons (idempotent)
make demo-fix            # clean baseline: every gate green, rollout Healthy
```
Open these browser tabs:
| Tab | URL |
|---|---|
| Jenkins | http://localhost:8080/job/sentinelops/ |
| Grafana → *DevSecOps Command Center* | http://localhost:30300 |
| Argo Rollouts dashboard (`make rollouts-dashboard`) | http://localhost:3100/rollouts/sentinelops |
| SonarQube | http://localhost:9000 |

Run one green pipeline (**Build Now** on `main`) shortly before the demo so the dashboard has fresh data.

## Script

| Time | Do | Say (feature) |
|---|---|---|
| 0:00 | Show the Jenkins stage view of the last green build | "13 stages: from commit to signed, canary-deployed and chaos-tested release in about 5 minutes." |
| 1:00 | `make demo-attack` | "This creates an attacker branch `demo/vulnerable` in a throw-away clone: a hardcoded AWS key, a vulnerable Django, a root container, then an unsigned image." |
| 1:30 | Point at **1/5 gitleaks** | "The secret never reaches the registry; stage 1 blocks it. Build #24 in Jenkins is a real occurrence." (F2) |
| 2:00 | **2/5 Trivy** | "Django 3.2.0 has fixable CRITICAL CVEs, so the gate fails the build and names the upgrade." (F2) |
| 2:30 | **3/5 root** | "checkov flags `USER root` in the Dockerfile, and even if someone bypasses CI, Kyverno refuses a root pod at admission." (F2) |
| 3:00 | **4/5 unsigned image** | "Pushed straight to our registry, skipping the pipeline: the cluster rejects it because it has no Cosign signature or attestations." (F2) |
| 3:30 | **5/5 DRS** + open `reports/demo/scoreboard.md` | "The Deployment Risk Score turns all evidence into one number; any leaked secret scores 100, so it is blocked." (F1) |
| 4:30 | `make demo-canary`, switch to the Argo dashboard / Grafana | "Now a *signed, approved* release with a hidden bug: half its requests return 500. Watch the canary at 10 %." (F3) |
| 6:00 | Analysis fails, rollout **aborted**, stable keeps serving | "No human acted: the Prometheus analysis breached the 5 % error SLO twice and Argo Rollouts rolled back. Users saw at most 10 % of traffic on the bad version for about a minute." (F3, SLO) |
| 7:00 | Grafana Command Center | "DORA metrics, risk-score trend, vulnerabilities, canary state, chaos recovery time, error budget, all in one place." (F7) |
| 8:00 | Jenkins: open a green build's stage 12 log | "Every release is also chaos-tested: 30 % of pods killed under CPU stress, recovered in about 10 s with 100 % probe success." (F4) |
| 8:30 | Open `explain.md` of a failed build | "When a build fails, the explainer redacts secrets from the log and gives root cause and fix (Claude if a key is set, otherwise rules)." (F5) |
| 9:00 | `docs/COST-REPORT.md` | "Infracost on every build, and the FinOps autopilot stops nodes and Jenkins at 20:00 IST; the demo day on AWS costs about $1.50." (F6) |
| 9:30 | `make demo-fix` | "One command removes every demo change and proves the baseline is clean again: all gates PASS." |

### Optional: the attack inside Jenkins (+3 min)
```bash
make demo-branch     # pushes demo/vulnerable: django==3.2.0 + USER root (no secret)
```
Then in Jenkins, open **SentinelOps → Scan Multibranch Pipeline Now**. The new `demo/vulnerable` job
goes red at **stage 6 (Trivy gate)**, checkov reports `CKV_DOCKER_8` in stage 4, and the build's
`explain.md` names the Django CVEs and the upgrade. `make demo-fix` deletes the branch.

> **Why the secret is never pushed:** `gitleaks git` scans every ref Jenkins has fetched, so a fake
> key on any branch would also fail `main`. The secret attack therefore runs in a local clone only.

## Expected output
`make demo-attack` ends with six PASS rows (each meaning the attack was **stopped**):
```
PASS Hardcoded AWS access key           gitleaks (stage 1)             BLOCKED
PASS Vulnerable dependency django==3.2.0 Trivy gate (stage 6)          BLOCKED
PASS Dockerfile 'USER root'             checkov CKV_DOCKER_8 (stage 4) FLAGGED
PASS Pod running as UID 0 (signed image) Kyverno pod-security          DENIED
PASS Unsigned image pushed to the trusted registry Kyverno verifyImages DENIED
PASS Whole attacker change set          Deployment Risk Score (stage 8) BLOCKED
```
`make demo-canary` ends with `PASS ... ROLLED BACK`. `make demo-fix` ends with five rows
(gitleaks, Trivy, checkov, Kyverno, rollout), all PASS. Exit code 0 means every expectation held.

## If something goes wrong on stage
| Symptom | Fix |
|---|---|
| `missing tool: trivy` | `make tools` |
| Trivy is slow the first time | It downloads its vulnerability DB once (~1 min); run `make demo-attack` once before the demo |
| `no deployed rollout` | Run the `main` pipeline once (**Build Now**) |
| Canary never fails | Load generator not running: `kubectl --context kind-sentinelops -n sentinelops-loadgen get pods`; `make cluster-addons` redeploys it |
| Rollout left *Degraded* after the canary demo | `make demo-fix` (redeploys the stable release with fault injection off) |

## Screenshots to capture for the report
1. `make demo-attack` terminal output with the scoreboard
2. `make demo-canary`: Argo dashboard showing the aborted canary, and the AnalysisRun `Failed`
3. Grafana Command Center during the canary (error-rate spike on the canary only)
4. Jenkins `demo/vulnerable` build red at stage 6, plus its `explain.md`
5. `make demo-fix` scoreboard, all PASS
