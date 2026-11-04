# Architecture

## 1. Design goals
| Goal | How it is met |
|---|---|
| **Secure by default** | Six gates between commit and production (gitleaks, Sonar quality gate, Trivy, Risk Score, Cosign signature, Kyverno admission); runtime is non-root, read-only, default-deny network |
| **Self-healing** | Canary analysis on SLOs with automatic rollback; chaos gate proves recovery on every release |
| **Observable** | Every gate emits metrics (Pushgateway) next to app and cluster metrics; dashboards and alerts are code |
| **Cost-aware** | Local mode costs $0; AWS mode is tagged, small, SPOT, scheduled to sleep, and designed to be destroyed after demos |
| **Reproducible** | Pinned versions (`versions.env`, `requirements*.txt`, image digests); one Makefile; `make verify` |
| **One codebase, two modes** | `MODE=local` (kind, local registry, LocalStack) vs `MODE=aws` (EKS, ECR); differences live only in values/tfvars files |

## 2. Pipeline sequence
```mermaid
sequenceDiagram
  autonumber
  actor Dev as Developer
  participant GH as GitHub
  participant J as Jenkins
  participant SQ as SonarQube
  participant R as Registry (ECR)
  participant K as Kubernetes API + Kyverno
  participant AR as Argo Rollouts
  participant P as Prometheus
  Dev->>GH: git push
  J->>GH: poll (2 min) / webhook
  J->>J: 1 gitleaks (full history)
  J->>J: 2 pytest + coverage ≥ 80 %
  J->>SQ: 3 analysis
  SQ-->>J: quality gate (webhook)
  J->>J: 4 checkov (+ Infracost) · 5 docker build · 6 Trivy gate · 7 Syft SBOM
  J->>J: 8 Deployment Risk Score (auto / canary / block)
  J->>R: 9 push, resolve digest
  J->>R: 10 cosign sign + attest (SBOM, vuln scan)
  J->>K: 11 helm upgrade (image@sha256)
  K->>R: verify signature + attestations
  K-->>AR: admitted Rollout
  loop canary 10 % → 50 % → 100 %
    AR->>P: AnalysisRun (error rate, p95)
    P-->>AR: pass / fail
  end
  AR-->>J: Healthy (or Degraded → auto-rollback)
  J->>K: 12 smoke test + chaos (pod kill, CPU stress)
  J->>P: 13 Pushgateway (DORA, DRS, chaos, vulns)
  J-->>Dev: Telegram / Slack (+ "Why:" from the explainer on failure)
```

## 3. Gates and what each one stops
```mermaid
flowchart LR
  c([commit]) --> g1{gitleaks}
  g1 -- secret --> x1([blocked])
  g1 --> g2{tests + Sonar gate}
  g2 -- fail --> x2([blocked])
  g2 --> g3{Trivy: fixable CRITICAL?}
  g3 -- yes --> x3([blocked])
  g3 --> g4{Risk Score}
  g4 -- "> 60" --> x4([blocked])
  g4 -- "30-60: long canary" --> s[sign + attest]
  g4 -- "< 30: short canary" --> s
  s --> g5{Kyverno: signed, attested, digest, non-root, trusted registry?}
  g5 -- no --> x5([denied])
  g5 --> g6{canary analysis: errors ≤ 5 %, p95 ≤ 300 ms}
  g6 -- breach --> x6([auto-rollback])
  g6 --> g7{chaos: recover ≤ 60 s, ≥ 95 % success}
  g7 -- fail --> x7([build failed, alert])
  g7 --> ok([released])
```
checkov runs as a **soft** gate: its findings raise the Risk Score instead of failing the build,
so IaC hygiene is weighed against everything else.

## 4. Canary state machine (Feature 3)
```mermaid
stateDiagram-v2
  [*] --> Canary10: new revision admitted
  Canary10 --> Canary50: pause elapsed, analysis OK
  Canary50 --> Full: pause elapsed, analysis OK
  Full --> Healthy: all replicas updated
  Canary10 --> Aborted: 3 failed measurements
  Canary50 --> Aborted: 3 failed measurements
  Aborted --> StableServing: scale canary down, keep stable ReplicaSet
  StableServing --> [*]: alert SentinelOpsCanaryRolledBack
  Healthy --> [*]
```
Traffic is split by replica count (10 replicas → exact 10 % / 50 %) so no service mesh is needed
(assumption A7). The background analysis queries only canary pods via the
`rollouts-pod-template-hash` label exported by the PodMonitor.

## 5. Local mode (zero cost)
```mermaid
flowchart TB
  subgraph Laptop["Windows laptop · WSL2 Ubuntu · Docker Desktop"]
    subgraph Compose["docker compose (local/docker-compose.yml)"]
      jen[Jenkins :8080<br/>custom image, JCasC]
      son[SonarQube :9000] --- pg[(Postgres)]
      ls[LocalStack :4566<br/>S3, DynamoDB, Lambda, EventBridge]
    end
    reg[(registry :5001)]
    subgraph Kind["kind cluster 'sentinelops' (1 node, K8s 1.34)"]
      app[sentinelops-app Rollout ×10<br/>NodePort 30080]
      mon[kube-prometheus-stack<br/>Prometheus 30090 · Grafana 30300 · Alertmanager 30093]
      pgw[Pushgateway 30091]
      kyv[Kyverno]
      arg[Argo Rollouts]
      lg[load generator]
    end
  end
  jen -- docker.sock --> reg
  jen -- kubeconfig --> Kind
  jen -- docker network 'kind' --> pgw
  reg -. kind-registry:5000 .-> app
```

## 6. AWS mode
```mermaid
flowchart TB
  admin([Your IP /32]) --> jsg
  admin --> api
  subgraph VPC["VPC 10.40.0.0/16 · 2 AZs (us-east-1a/b) · flow logs → S3"]
    subgraph Public["public subnets"]
      jsg[Jenkins + SonarQube EC2<br/>t3.large · Ansible-configured]
      nat[NAT gateway ×1]
    end
    subgraph Private["private subnets"]
      ng[EKS managed node group<br/>2 × t3.medium SPOT]
    end
  end
  api[EKS 1.35 control plane<br/>public endpoint restricted to admin CIDR] --- ng
  ng --> nat
  jsg --> ecr[(ECR · immutable tags · scan on push · lifecycle)]
  ng --> ecr
  sm[(Secrets Manager)] --- ng
  kms[(KMS key)] --- api
  eb[EventBridge 20:00 IST] --> fl[FinOps Lambda] --> ng
  fl --> jsg
  ssm[(SSM override)] --> fl
  s3[(S3 state + DynamoDB lock)] -.- tf[Terraform]
```
In AWS Academy, `lab_mode = true` uses the pre-created `LabRole` / `LabInstanceProfile` because
the learner lab cannot create IAM roles or OIDC providers. With `lab_mode = false` the `iam`
module creates dedicated roles and the `eks` module adds the OIDC provider and an IRSA role for
the app ServiceAccount that can read only its own secret.

## 7. Observability data flow
| Source | Collected by | Used in |
|---|---|---|
| App `/metrics` (requests, latency histogram, revision label) | PodMonitor → Prometheus | SLO recording rules, canary analysis, SLO dashboard |
| Pipeline events (start/end, result, lead time, DRS, vulns, chaos) | Jenkins → Pushgateway | DORA recording rules, Command Center |
| Nodes / Kubernetes objects | node-exporter, kube-state-metrics | Cluster Health dashboard, Command Center |
| Argo Rollouts, Kyverno controllers | ServiceMonitors | canary status, admission decisions |
| Alerts | Alertmanager | Telegram / Slack; each alert links to a [runbook](RUNBOOK.md) section |

## 8. Key design decisions
| Decision | Alternative considered | Why |
|---|---|---|
| kind + local registry for local EKS/ECR | LocalStack EKS/ECR | Those are LocalStack Pro (paid) features |
| Cosign **key pair** | Keyless (Fulcio/Rekor + OIDC) | Works offline and identically in kind and EKS; the key is a Jenkins credential |
| Kyverno legacy `ClusterPolicy` for attestations | `ImageValidatingPolicy` | Kyverno 1.19.2's CEL policy requires a Rekor bundle, which offline signing does not produce (see PROGRESS, Phase 5) |
| Replica-based canary | Istio / Linkerd traffic routing | A mesh costs about 2 GB RAM; replica weights are exact with 10 pods |
| kubectl chaos engine (`tools/chaos`) | Chaos Mesh / Litmus | No extra operator or CRDs, same code on kind and EKS; the brief allows a kubectl fallback |
| Pushgateway for pipeline metrics | Jenkins Prometheus plugin | Batch-job semantics; metrics survive Jenkins restarts and carry build labels |
| Dashboards generated from Python | Hand-edited JSON | Tested (unique IDs, no overlap, valid queries, Feature 7 coverage) and diff-friendly |
| GitHub Actions only mirrors `make verify` | Running the full pipeline in Actions | The delivery pipeline needs the cluster; Actions gives a public, independent check and badge |
