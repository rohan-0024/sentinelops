# Project report outline

**Title:** Secure CI/CD Pipeline for Containerized Applications with AWS: *SentinelOps, a
self-defending, cost-aware DevSecOps platform*
**Suggested length:** 45-60 pages including appendices · numbered figures and tables · IEEE references.

Each chapter lists its content, the repository source to draw from, and the figures and tables to
include (figure numbers refer to [SCREENSHOTS.md](SCREENSHOTS.md)).

## Front matter
Title page · Bonafide certificate · Declaration · Acknowledgements · Abstract (250 words: problem,
approach, the seven features, key results such as the 5-minute pipeline, 6/6 attacks blocked,
9.7 s chaos recovery, auto-rollback, $0 local / about $1.50 per AWS demo day) · Table of contents ·
List of figures · List of tables · Abbreviations (CI/CD, SBOM, SLSA, SLO, DORA, IRSA, DRS…)

## 1. Introduction (4-5 pages)
1.1 Background: DevOps, DevSecOps, "shift left" and "shield right"
1.2 Problem statement: manual deployment is slow, error-prone and insecure (from the brief)
1.3 Objectives: the 13-stage pipeline, the 7 features, two execution modes
1.4 Scope and constraints: AWS Academy Learner Lab, 16 GB laptop, zero-cost local mode
1.5 Organisation of the report
*Source:* README, `docs/ASSUMPTIONS.md`

## 2. Literature survey and related work (5-6 pages)
2.1 CI/CD tools (Jenkins, GitHub Actions, GitLab CI) · 2.2 Container security (image scanning, distroless, non-root)
2.3 Software supply-chain attacks (SolarWinds, Codecov, the 2026 Trivy release incident in `docs/SECURITY-NOTES.md`) and frameworks (SLSA, Sigstore, SBOM)
2.4 Progressive delivery and SRE (canary, SLOs, error budgets, burn-rate alerts)
2.5 Chaos engineering · 2.6 DORA metrics · 2.7 FinOps · 2.8 LLMs for operations
2.9 Gap analysis table: existing pipelines vs SentinelOps (risk-based gating, admission-enforced attestations, chaos as a gate)

## 3. Requirements analysis (3-4 pages)
3.1 Functional requirements (the 13 stages, 7 features, attack mode)
3.2 Non-functional requirements: security, reproducibility, cost, observability
3.3 Hardware and software requirements (pinned versions from `versions.env`)
3.4 Requirement traceability → `docs/TRACEABILITY.md` (Table 3.1)

## 4. System design (8-10 pages)
4.1 Architecture overview (Fig. 4.1 from README Mermaid)
4.2 Pipeline sequence (Fig. 4.2) and gate decision flow (Fig. 4.3)
4.3 Local-mode and AWS-mode deployment views (Figs 4.4, 4.5)
4.4 Canary state machine (Fig. 4.6)
4.5 Data and metrics flow (Table 4.1)
4.6 Design decisions and alternatives (Table 4.2)
4.7 Threat model: STRIDE summary table (full table in Appendix C)
*Source:* `docs/ARCHITECTURE.md`, `docs/THREAT-MODEL.md`

## 5. Implementation (12-15 pages)
5.1 Sample microservice and container image (code listing: Dockerfile; Fig. image size and user)
5.2 Infrastructure as Code: Terraform modules, lab_mode, remote state, tagging (Listing: module call)
5.3 Configuration management: Ansible roles and Molecule
5.4 Jenkins: JCasC, shared library, 13 stages (Listing: Jenkinsfile excerpt)
5.5 Code quality and security scanning: SonarQube, Trivy, checkov, gitleaks
5.6 Kubernetes: Helm chart, Argo Rollouts, AnalysisTemplate, NetworkPolicy, PDB
5.7 Feature 1: Deployment Risk Score (formula, `policy/risk.yaml`, Table of weights)
5.8 Feature 2: Zero-trust supply chain (Cosign, SBOM, Kyverno policies, SLSA provenance)
5.9 Feature 3: Self-healing canary and SLOs (rules, burn rates)
5.10 Feature 4: Chaos gate (experiment design, pass criteria)
5.11 Feature 5: AI failure explainer (redaction, prompt, rule fallback)
5.12 Feature 6: FinOps autopilot (Lambda, EventBridge, Infracost, cost model)
5.13 Feature 7: DevSecOps Command Center (dashboards as code)
5.14 Attack mode and demo automation

## 6. Testing and verification (5-6 pages)
6.1 Strategy: unit → static analysis → integration (pipeline) → live demos
6.2 Unit tests: app 18 tests (98.9 % coverage), tools 87 tests, Rego tests, promtool tests (Table 6.1)
6.3 Static analysis results: ruff, yamllint, shellcheck, ansible-lint, checkov 0 failed, tflint, helm lint (Table 6.2)
6.4 Pipeline runs: build #28 all 13 stages green (Fig. 6.1), stage timings
6.5 Security tests: `make demo-attack` 6/6 blocked (Table 6.3), `make demo-supply-chain` 4/4
6.6 Resilience tests: `make demo-canary` auto-rollback (Fig. 6.x), chaos gate results
6.7 Bugs found by the pipeline itself during development (gitleaks on fake fixtures, SIGPIPE in deploy, checkov paths), a good discussion point
*Source:* `docs/PROGRESS.md`, Jenkins artifacts, `reports/demo/scoreboard.md`

## 7. Results and discussion (4-5 pages)
7.1 Pipeline duration per stage · 7.2 Risk Score across builds (59 → 54 after the checkov fix)
7.3 DORA metrics from the Command Center · 7.4 Cost analysis (`docs/COST-REPORT.md`)
7.5 SLSA level achieved (`docs/SLSA.md`) · 7.6 Comparison with the objectives (met / partially met)
7.7 Limitations: AWS mode verified with `terraform plan` only / L3 not met / replica-based canary granularity

## 8. Conclusion and future work (2 pages)
Summary of contributions; future work: SLSA L3 (KMS signer, ephemeral agents), provenance
enforcement, WAF, multi-service DORA, GitOps (Argo CD).

## References (IEEE style, 20-30)
SLSA v1.0 spec · Sigstore/Cosign docs · Kyverno docs · Argo Rollouts docs · Google SRE Workbook
(alerting on SLOs) · DORA "Accelerate" / State of DevOps reports · OWASP Top 10 CI/CD Security
Risks · CIS Docker and Kubernetes benchmarks · NIST SP 800-190 (container security) and
SP 800-218 (SSDF) · AWS EKS Best Practices Guide · Terraform and Ansible docs · Trivy, Syft,
SonarQube, checkov, gitleaks docs · Infracost docs · Anthropic Messages API docs.

## Appendices
A. Installation and user guide (README quick start + Makefile targets)
B. Jenkinsfile and key configuration listings
C. Full STRIDE threat model
D. Runbook (`docs/RUNBOOK.md`)
E. Demo script (`docs/DEMO.md`) and viva Q&A
F. Screenshots (checklist in `docs/SCREENSHOTS.md`)
