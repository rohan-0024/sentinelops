#!/usr/bin/env bash
# Live check against Prometheus (local mode, NodePort 30090): are the metrics our
# rules and dashboards use actually present, and are the SentinelOps rules loaded?
set -euo pipefail
PROM="${PROM_URL:-http://localhost:30090}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
curl -fsS "${PROM}/api/v1/label/__name__/values" -o "${TMP}/names.json"
curl -fsS "${PROM}/api/v1/rules" -o "${TMP}/rules.json"
curl -fsS "${PROM}/api/v1/alerts" -o "${TMP}/alerts.json"

python3 - "${TMP}" <<'PY'
import json
import sys
from pathlib import Path

d = Path(sys.argv[1])
names = set(json.loads((d / "names.json").read_text())["data"])
wanted = [
    "http_requests_total", "http_request_duration_seconds_bucket", "up",
    "rollout_info", "analysis_run_info", "kyverno_admission_requests_total",
    "kube_pod_status_ready", "kube_pod_container_status_restarts_total",
    "node_cpu_seconds_total", "container_memory_working_set_bytes",
    "sentinelops_build_success", "sentinelops_vulnerabilities_critical",
    "sentinelops_deploy_timestamp_seconds",
]
print("== metrics used by rules/dashboards")
for m in wanted:
    print(f"  {'present' if m in names else 'MISSING'}  {m}")

print("== SentinelOps rule groups")
groups = [g for g in json.loads((d / "rules.json").read_text())["data"]["groups"] if g["name"].startswith("sentinelops")]
for g in groups:
    bad = [r["name"] for r in g["rules"] if r.get("health") != "ok"]
    status = "ok" if not bad else "BAD " + ", ".join(bad)
    print(f"  {g['name']:<32} {len(g['rules']):>2} rules  health: {status}")
print(f"  {len(groups)} groups loaded")

print("== SentinelOps alerts (pending/firing)")
alerts = [a for a in json.loads((d / "alerts.json").read_text())["data"]["alerts"]
          if a["labels"]["alertname"].startswith("SentinelOps")]
for a in alerts:
    print(f"  {a['state']:<8} {a['labels']['alertname']} ({a['labels'].get('severity')})")
if not alerts:
    print("  none")
PY
