# SentinelOps SLOs

| | Definition |
|---|---|
| **Service** | `sentinelops-app`, requests to `/api/*` (health probes and `/metrics` excluded) |
| **Availability SLI** | share of `/api` requests answered with a non-5xx status |
| **Availability SLO** | **99 %** over the SLO period, so the **error budget is 1 %** |
| **Latency SLI / SLO** | p95 of `/api` request duration **≤ 300 ms** |
| **SLO period** | 7 days in the lab (Prometheus keeps 7 days locally); 30 days is the production norm |

## Error budget and burn rate
- `sentinelops:error_budget:remaining_ratio = 1 − (7d error ratio ÷ 0.01)`, floored at 0.
- **Burn rate** = observed error ratio ÷ allowed error ratio (0.01). Burn rate 1 spends the
  budget exactly over the period; 14.4 spends 2 % of a 30-day budget in one hour.

## Alerts (multi-window, multi-burn-rate, Google SRE Workbook ch. 5)
| Alert | Condition | Severity | Why two windows |
|---|---|---|---|
| ErrorBudgetFastBurn | burn > 14.4 over **1h** AND **5m**, for 2m | critical | 1h proves it is significant; 5m makes it reset fast once fixed |
| ErrorBudgetSlowBurn | burn > 6 over **6h** AND **30m**, for 5m | warning | catches slow leaks a fast alert misses |
| LatencySLOBreach | p95 > 300 ms for 5m | warning | |
| AppDown | no app pod scraped for 3m | critical | inhibits the SLO alerts (they would only add noise) |

A short spike (minutes) does not page because the 1h window stays under 14.4x; this is
covered by the promtool test "short spike does not page".

## The same SLOs gate releases
The Argo Rollouts AnalysisTemplate (`k8s/charts/sentinelops-app`) applies the same
thresholds per canary revision: error rate ≤ 5 % and p95 ≤ 300 ms. A breach aborts the
canary and restores the stable version before the error budget is hurt.

## Tests
- `make monitoring-test`: promtool unit tests (`monitoring/tests/*.test.yaml`) replay
  synthetic metric histories and assert exactly which alerts fire, plus `amtool check-config`.
- `tools/tests/test_rules.py`: every alert has a severity, summary and an existing runbook section.
