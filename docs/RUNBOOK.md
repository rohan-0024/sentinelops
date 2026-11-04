# SentinelOps runbook

One section per alert (alert annotations link here). Commands assume local mode
(`--context kind-sentinelops`, with `~/sentinelops/.bin` on PATH).

## error-budget-burn
**Alerts:** `SentinelOpsErrorBudgetFastBurn` (critical), `SentinelOpsErrorBudgetSlowBurn` (warning)
1. Grafana → *SentinelOps · Service SLO*: which status codes rose, and is it one revision (canary vs stable panel)?
2. A rollout in progress? `kubectl argo rollouts get rollout sentinelops-app -n sentinelops`. If the canary is bad and analysis has not aborted yet: `kubectl argo rollouts abort sentinelops-app -n sentinelops`.
3. Fault injection left on? `kubectl -n sentinelops get rollout sentinelops-app -o jsonpath='{.spec.template.spec.containers[0].env}'` (FAULT_ERROR_RATE should be "0").
4. Otherwise roll back to the previous revision: `kubectl argo rollouts undo sentinelops-app -n sentinelops`.

## latency
**Alert:** `SentinelOpsLatencySLOBreach`
1. Check CPU throttling / memory in *SentinelOps · Cluster Health*.
2. Check `FAULT_LATENCY_MS` on the pods (see above) and recent deploys.

## app-down
**Alert:** `SentinelOpsAppDown`
1. `kubectl -n sentinelops get pods,rs,events --sort-by=.lastTimestamp | tail -20`
2. Admission denials (Kyverno) or image pull errors are the usual causes; see [admission-denied](#admission-denied).

## pipeline-failure
**Alert:** `SentinelOpsPipelineFailing`
1. Open the failed build in Jenkins; the failing stage is in the notification.
2. Read `reports/explain.md` (AI failure explainer, Feature 5) in the build artifacts.
3. Gate failures (gitleaks, Sonar, Trivy, DRS) are working as intended: fix the finding, do not bypass the gate.

## canary-rollback
**Alerts:** `SentinelOpsCanaryRolledBack` (critical), `SentinelOpsCanaryAnalysisFailed` (warning)
Argo Rollouts already restored the stable version; production is safe.
1. `kubectl argo rollouts get rollout sentinelops-app -n sentinelops` → which AnalysisRun failed.
2. `kubectl -n sentinelops describe analysisrun <name>` → which metric (error-rate / p95-latency) and the measured values.
3. Fix the release and push again; the alert clears when a new revision becomes Healthy.

## admission-denied
**Alert:** `SentinelOpsAdmissionDenied` (info)
Kyverno blocked a pod in the enforced namespace. Expected during `make demo-supply-chain` and the attack demo.
1. `kubectl -n sentinelops get events --field-selector reason=FailedCreate`
2. The message names the failing control: signature, vulnerability-scan/SBOM attestation, trusted registry/digest, or pod security.
3. A real release being blocked usually means stage 10 (Cosign) was skipped: check `COSIGN_KEY_B64` in `.env`.

## vulnerabilities
**Alert:** `SentinelOpsCriticalVulnerabilities` (info)
Fixable CRITICALs already fail the pipeline (Trivy gate). This alert reports unfixable ones.
1. Inspect `reports/trivy-image.json` in the build artifacts.
2. Rebuild on a newer base image; if accepted, document it in `.trivyignore` with a reason and review date.

## monitoring
**Alert:** `SentinelOpsPushgatewayDown`
1. `kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-pushgateway`
2. Re-run `make cluster-addons`.

## chaos
**Alert:** `SentinelOpsChaosRecoverySlow`
1. Check the chaos stage log (pipeline stage 12) for the experiment and recovery timeline.
2. Usual causes: slow image pull, readiness probe too strict, too few replicas, or node memory pressure.

---

# Day-2 operations

## start-stop
| Task | Command |
|---|---|
| Start everything (idempotent) | `make local-up` |
| Status | `make local-status`, `make rollout-status` |
| Stop, keep data | `make local-down` |
| Stop and wipe volumes | `make local-clean` (SonarQube must be re-bootstrapped: `make sonar-bootstrap`) |
| Laptop rebooted, Jenkins cannot reach the cluster | `make jenkins-kubeconfig` |

## demo-reset
After rehearsals or a failed demo: `make demo-fix` removes the demo clone, branch and image,
turns fault injection off, redeploys the stable release and re-checks every gate (expect 5 × PASS).

## rotate-cosign-key
1. Delete the old pair (`rm local/secrets/cosign.key policy/keys/cosign.pub`), then `make cosign-keygen`: the private key goes to `local/secrets/` and `COSIGN_KEY_B64` in `.env`, the public key to `policy/keys/cosign.pub` (commit it).
2. `make local-up` (reloads Jenkins credentials) and `make policies` (Kyverno gets the new public key).
3. Run the pipeline: images signed with the old key are rejected on their next rollout, so redeploy.

## secret-leak
A real credential reached git (gitleaks alert, or found later):
1. **Revoke/rotate the credential first**; history rewriting does not un-leak it.
2. Remove it from the code, store it in `.env` / Jenkins credentials / Secrets Manager.
3. If it must leave history: `git filter-repo --replace-text`, force-push, ask collaborators to re-clone.
4. Only for false positives: add the fingerprint to `.gitleaksignore` with a comment.

## aws-session
AWS Academy sessions expire after about 4 hours.
1. Refresh `~/.aws/credentials` from the Learner Lab "AWS Details" page (never commit or paste them in chat).
2. `make aws-plan` before anything else; `make aws-destroy` at the end of every session.
3. Forgot to destroy? The FinOps autopilot scales nodes to 0 and stops Jenkins at 20:00 IST, but the
   control plane and NAT keep billing until `make aws-destroy`.
4. Keep it running through the night (rare): `aws ssm put-parameter --overwrite --name /sentinelops/finops/override --value keep-alive`.

## disk-space
Docker Desktop fills up after many builds: `docker system df`, then `docker image prune -a --filter "until=72h"`
and `docker builder prune --keep-storage 10GB`. The kind node: `docker exec sentinelops-control-plane crictl rmi --prune`.
