# Viva preparation: 30 likely questions

Short answers you can say aloud, with the file or evidence to point at.

## A. Problem, scope and design
**1. What problem does the project solve?**
Manual deployment is slow, inconsistent and insecure. SentinelOps automates the path from a git
push to a running, monitored release in about five minutes. Every step that a human might skip
(scanning, signing, testing in production-like conditions) becomes an enforced gate.

**2. What is novel compared with a standard Jenkins → Docker → Kubernetes pipeline?**
Seven additions:
- a transparent Deployment Risk Score that decides *how* to deploy;
- a zero-trust supply chain enforced by the cluster itself;
- self-healing canary releases;
- a chaos gate on every release;
- an AI failure explainer;
- a FinOps autopilot;
- a single Command Center dashboard.

There is also an attack-mode demo that proves the gates work.

**3. Why two modes, local and AWS?**
AWS Academy credits are limited and sessions expire after about 4 hours. Local mode (kind,
Compose, LocalStack) costs nothing and runs the same pipeline, Helm chart and policies. Only the
values and tfvars files differ (`MODE=local|aws`), so what we test locally is what we deploy to EKS.

**4. Why Jenkins and not GitHub Actions?**
The brief and the course slides specify Jenkins. It is also self-hosted, which keeps the cluster
credentials inside our network. GitHub Actions is still used as an independent mirror of `make verify`
for a public build badge.

**5. Why Python FastAPI for the sample service?**
It is small and fast to test (18 tests, 98.9 % coverage). It exposes Prometheus metrics natively
and runs on a distroless Python image of about 100 MB. It also has built-in fault injection
(`FAULT_ERROR_RATE`, `FAULT_LATENCY_MS`) for the canary demo.

## B. Pipeline and security gates
**6. Walk me through the 13 stages.**
1. gitleaks
2. tests and coverage
3. SonarQube quality gate
4. checkov and Infracost
5. Docker build
6. Trivy gate
7. Syft SBOM
8. Risk Score
9. push by digest
10. Cosign sign and attest
11. Helm canary deploy
12. smoke and chaos test
13. metrics and notification

The explainer runs in the post-failure step.

**7. What happens if a developer commits an AWS key?**
Stage 1 (gitleaks over the full git history) fails the build before anything is built. That
happened for real in build #24, with fake test fixtures. A secret also scores 100 in the DRS, so
it can never be deployed. `make demo-attack` reproduces it.

**8. Why does Trivy fail only on *fixable* CRITICAL vulnerabilities?**
A gate must be actionable. If no fixed version exists, failing every build would only teach
people to bypass the gate. Unfixable CRITICALs and all HIGHs still add points to the Risk Score
and raise an informational alert.

**9. How is the Deployment Risk Score calculated?**
score = min(100, Σ min(cap, weight × count)), plus a penalty for each missing report. The weights
are in `policy/risk.yaml`; for example, a fixable HIGH CVE is worth 3 points, capped at 24. Below
30 the release deploys with 15 s canary pauses. From 30 to 60 it deploys with 60 s pauses. Above
60 it is blocked. Build #28 scored 54 (canary), and every factor is shown in `drs.md`.

**10. Isn't a weighted score arbitrary?**
The weights are a policy decision. The point is that they are explicit, versioned and reviewable
in one YAML file, instead of hidden in someone's judgement. The hard gates still block the
clear-cut cases; the score weighs the residual risk. It is unit-tested (14 tests), and Rego rules
check that its decision is consistent with its own thresholds.

**11. What is SonarQube's role if we already have Trivy?**
They look at different things. Trivy finds known CVEs in dependencies and the OS. SonarQube
analyses *our* code for bugs, code smells, security hotspots and coverage. The quality gate fails
the build, and its measures feed the DRS.

**12. Why checkov as a soft gate?**
IaC findings vary a lot in severity. Hard-failing on all of them encourages blanket skips. Each
failed check adds 2 points to the DRS, capped at 20. The repo itself has 0 failed checks, and its
28 skips each carry an inline justification.

## C. Supply chain (Feature 2)
**13. How does the cluster know an image is trustworthy?**
Kyverno admission policies, scoped to namespaces labelled `sentinelops.io/enforce=true`, require:
- a Cosign signature from the pipeline key;
- SBOM and vulnerability-scan attestations;
- a digest reference, not a tag;
- the trusted registry;
- non-root and read-only security settings.

`make demo-supply-chain` shows four cases: three images rejected and the signed one admitted.

**14. Why sign with a key pair instead of keyless Sigstore?**
Keyless needs OIDC plus public Fulcio and Rekor, which don't fit an offline kind cluster or an
Academy lab. The private key is a Jenkins credential and the public key is in the policy.
`docs/SLSA.md` explains how to move to KMS or keyless for SLSA L3.

**15. What SLSA level do you reach?**
Build L2 in AWS mode: a hosted builder, and signed SLSA v1 provenance attached to every image
(`make provenance-check`). Build L1 in local mode. Not L3, because pipeline steps can read the
signing key and builds share an executor. The roadmap to L3 is in `docs/SLSA.md`.

**16. What is an SBOM and why attach it?**
A Software Bill of Materials lists every package in the image (48 components for our image). It
is attested, meaning signed and bound to the digest. When a new CVE is published, you can answer
"are we affected?" without rebuilding, and the cluster can require that an SBOM exists.

## D. Delivery, reliability and chaos
**17. How does the canary work without a service mesh?**
The Rollout has 10 replicas, so moving 1 pod and then 5 pods to the new version gives exactly
10 % and 50 % of the traffic. During the canary, a background AnalysisRun queries Prometheus
every 20 s for the canary pods' error rate (≤ 5 %) and p95 latency (≤ 300 ms).

**18. What triggers a rollback, and how fast is it?**
More than 2 failed measurements (failureLimit 2). In `make demo-canary`, 50 % of the canary's
requests returned errors. The analysis failed 3 times, and Argo Rollouts aborted within about a
minute of the first bad measurement, with no human action. Users saw the bad version on at most
10-50 % of the traffic during that window. An alert (`SentinelOpsCanaryRolledBack`) fires.

**19. What are your SLOs and how are they alerted?**
99 % of requests succeed and p95 latency is at most 300 ms, measured over 30 days. The alerts use
multi-window burn rates from the Google SRE workbook:
- 14.4× over 1 h and 5 m (pages: 2 % of the monthly budget gone in an hour);
- 6× over 6 h and 30 m (warning).

promtool unit tests prove the alerts fire and stay quiet when they should.

**20. What does the chaos gate do?**
After each deploy it deletes 30 % of the pods and runs two CPU-hog pods for 20 s, probing the
service the whole time. It passes only if the deployment is fully available again within 60 s
and at least 95 % of probes succeed. Build #28: 3 of 10 pods killed, recovered in 9.7 s, 149
probes at 100 %, p95 10 ms.

**21. Why not Chaos Mesh?**
It adds an operator, CRDs and memory to a 16 GB laptop. The brief allows a kubectl fallback, and
`tools/chaos` runs the same pod-kill and stress experiment through the Kubernetes API on kind and
EKS. Its results are pushed as metrics.

## E. Observability, AI and FinOps
**22. How do you compute DORA metrics?**
Jenkins pushes per-build events to the Pushgateway: start time, commit time, deploy result, and
whether a failure happened in the deploy or chaos stages. Prometheus recording rules turn them
into the four metrics:
- deployment frequency (per day over 7 d);
- lead time (commit to deploy);
- change failure rate;
- time to restore.

These are approximations for a single service; assumption A11 says so.

**23. What does the AI failure explainer send to the API, and is it safe?**
Only the last 400 log lines of the failed build, after redaction. Redaction covers:
- known token formats (AWS, GitHub, Slack, Anthropic, Sonar, JWT);
- private keys and credentials embedded in URLs;
- `password=` style assignments;
- the literal values of the pipeline's secret variables.

The explainer has 27 tests. Without an API key, or if the call fails, a rule engine covering every
pipeline failure mode answers instead, so the feature always works.

**24. How does the FinOps autopilot save money?**
An EventBridge schedule at 20:00 IST invokes a Lambda. It scales the EKS node group to 0 and
stops instances tagged `Schedule=office-hours`, which includes Jenkins. An SSM parameter
(`keep-alive`) overrides it, and the same logic runs locally as a CLI. Infracost on each build
shows the cost impact of a Terraform change before it is applied. The always-on part (control
plane and NAT) is why demos use apply → demo → destroy, at about $1-1.50 per day.

**25. How are Grafana dashboards provisioned?**
As code: a Python generator writes JSON into ConfigMaps that Grafana's sidecar loads
automatically. Tests check for unique panel IDs, no overlapping panels and balanced queries, and
that the Command Center covers every signal the brief requires.

## F. Infrastructure and operations
**26. How is the AWS infrastructure built, and how do you avoid accidents?**
Terraform modules: `vpc`, `eks`, `ecr`, `iam`, `jenkins-ec2`, `state-backend` and `finops`. State
is kept in S3 with a DynamoDB lock. Every resource is tagged (`AutoTeardown=true`). Checks:
`validate`, `tflint` and checkov (0 failed). `make aws-plan` creates nothing. `aws-apply` needs a
saved plan and typing `APPLY`, and `aws-destroy` needs typing `DESTROY`.

**27. What is lab_mode?**
AWS Academy Learner Lab forbids creating IAM roles and OIDC providers. With `lab_mode = true`,
Terraform reuses the provided `LabRole` and `LabInstanceProfile`. With `lab_mode = false`
(a standard account), it creates least-privilege roles and IRSA for the app.

**28. What does Ansible do here?**
It configures the Jenkins EC2 in AWS mode. Roles:
- `hardening`: ssh, fail2ban, unattended upgrades, sysctl;
- `docker`;
- `node_exporter`;
- `trivy`;
- `sonarqube`;
- `jenkins`.

Molecule runs converge, idempotence (0 changed on the second run) and 11 verify checks in a
container. ansible-lint passes with the production profile.

**29. How do you know it all works, and what is `make verify`?**
`make verify` runs:
- ruff, yamllint and shellcheck;
- ansible-lint;
- 18 app tests (coverage gate 80 %) and 87 tool tests;
- checkov;
- terraform validate and tflint;
- promtool and amtool;
- helm lint;
- Rego policy tests.

It runs on the laptop and in GitHub Actions. Phases 4-8 were verified end to end on the laptop
(builds #18 and #28, plus the demos). `docs/PROGRESS.md` records what was verified and where.

**30. What would you improve with more time?**
- SLSA L3: KMS signer, ephemeral build agents, and provenance enforced at admission.
- Branch protection and signed commits.
- An ingress controller with rate limiting or WAF for internet exposure.
- Multi-service DORA.
- Running the full AWS path regularly in CI with short-lived credentials.
