# SentinelOps cost report (Feature 6: FinOps Autopilot)

## How costs are measured
| Source | When | Output |
|---|---|---|
| **Infracost** in pipeline stage 4 | every build (when `INFRACOST_API_KEY` is set) | `reports/infracost.json`, `reports/cost-report.md` (build artifacts) |
| `make cost-report` | on demand, laptop | same, under `./reports` |
| Tags on every resource | always | `Project=sentinelops`, `Owner`, `Environment`, `ManagedBy=terraform`, `AutoTeardown=true`, `CostCenter=academic` for AWS Cost Explorer grouping |

`tools/finops/cost_report.py` splits the Infracost breakdown into:
- **schedulable** resources, billed only while running: EKS node group (launch template) and the Jenkins EC2. The autopilot stops these out of hours.
- **always-on** resources: EKS control plane, NAT gateway, KMS, Secrets Manager and log groups. Only `make aws-destroy` removes these.

It then projects the monthly bill with the autopilot schedule (default 176 h/month on, i.e. 8 h × 22 working days).

## Reference estimate (us-east-1 on-demand list prices; confirm with Infracost)
Unit prices are long-standing AWS list prices; they change rarely but **regenerate with
`make cost-report` before quoting them**.

| Resource (Terraform default sizes) | Unit price | 24/7 per month (730 h) | Schedulable |
|---|---|---:|:---:|
| EKS control plane (1.35, standard support) | $0.10 / h | $73.00 | no |
| NAT gateway (1, hourly part only) | $0.045 / h + $0.045 / GB | $32.85 + data | no |
| 2 × t3.medium nodes, ON_DEMAND | $0.0416 / h each | $60.74 | yes |
| 2 × t3.medium nodes, **SPOT (default)** | typically ~60-70 % below on-demand | ≈ $18-24 | yes |
| Jenkins + SonarQube host, t3.large | $0.0832 / h | $60.74 | yes |
| EBS gp3 (2 × 20 GB nodes + 30 GB Jenkins) | $0.08 / GB-month | $5.60 | no (volumes persist) |
| KMS key / Secrets Manager secret | $1.00 / $0.40 per month | $1.40 | no |
| ECR, CloudWatch logs (7-14 day retention), Lambda, EventBridge | usage-based | < $2 at lab volumes | n/a |

**What this means for the project**
| Scenario | Approximate cost |
|---|---:|
| Left running 24/7 with SPOT nodes | ≈ $195 / month |
| With the FinOps autopilot (stop at 20:00 IST, nodes at 0, Jenkins stopped), 8 h × 22 days | ≈ $125 / month: about $70 saved; the control plane and NAT dominate what is left |
| **Demo day only:** apply → 4 h demo → `make aws-destroy` | **≈ $1-1.50 total** |

The project's real FinOps stance follows from this: in AWS Academy (credit-limited) the
EKS environment is **ephemeral**: `make aws-plan` / `make aws-apply` for the demo and
screenshots, then `make aws-destroy`. The autopilot is the safety net for the night you
forget.

## Cost controls implemented
1. **Smallest viable sizes** with SPOT nodes by default (`node_capacity_type`), two instance types for SPOT availability.
2. **Single NAT gateway** instead of one per AZ (saves ≈ $33/month per extra AZ).
3. **EKS 1.35 in standard support**: an expired version would bill extended support at 6× the control-plane price.
4. **Short log retention** (EKS 7 days, Lambda 14 days) and ECR lifecycle rules (untagged images expire after 3 days, keep last 20).
5. **FinOps autopilot** (`terraform/modules/finops`, `tools/finops/handler.py`): an EventBridge schedule (14:30 UTC = 20:00 IST) invokes a Lambda that scales the node group to 0 and stops `Schedule=office-hours` instances.
   - **Manual override:** `aws ssm put-parameter --overwrite --name /sentinelops/finops/override --value keep-alive`
   - **Same logic locally:** `python -m tools.finops.handler status|stop|start [--dry-run]`
6. **Infracost on every build** makes the cost impact of each Terraform change visible before it is applied.
7. **Gated apply:** `make aws-apply` refuses to run without a saved plan and typing `APPLY`.

## Local mode
Zero cloud cost: kind, Compose and LocalStack run on the laptop. `make local-down`
stops everything and keeps state.
