#!/usr/bin/env bash
# Live check against Prometheus (local mode, NodePort 30090): are the metrics our
# rules and dashboards use actually present, and are the SentinelOps rules loaded?
set -euo pipefail
PROM="${PROM_URL:-http://localhost:30090}"
PY=python3

names="$(curl -fsS "${PROM}/api/v1/label/__name__/values")"
echo "== metrics used by rules/dashboards"
for m in http_requests_total http_request_duration_seconds_bucket up \
         rollout_info analysis_run_info kyverno_admission_requests_total \
         kube_pod_status_ready kube_pod_container_status_restarts_total \
         node_cpu_seconds_total container_memory_working_set_bytes \
         sentinelops_build_success sentinelops_vulnerabilities_critical sentinelops_deploy_timestamp_seconds; do
  if "${PY}" -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin)["data"] else 1)' "${m}" <<<"${names}"; then
    printf '  present  %s\n' "${m}"
  else
    printf '  MISSING  %s\n' "${m}"
  fi
done

echo "== SentinelOps rule groups"
curl -fsS "${PROM}/api/v1/rules" | "${PY}" -c '
import json, sys
groups = [g for f in [json.load(sys.stdin)["data"]["groups"]] for g in f if g["name"].startswith("sentinelops")]
for g in groups:
    bad = [r["name"] for r in g["rules"] if r.get("health") != "ok"]
    print(f"  {g[\"name\"]:<32} {len(g[\"rules\"]):>2} rules  health: {\"ok\" if not bad else \"BAD \" + \", \".join(bad)}")
print(f"  {len(groups)} groups loaded")'

echo "== firing SentinelOps alerts"
curl -fsS "${PROM}/api/v1/alerts" | "${PY}" -c '
import json, sys
a = [x for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"]["alertname"].startswith("SentinelOps")]
print("\n".join(f"  {x[\"state\"]:<8} {x[\"labels\"][\"alertname\"]} ({x[\"labels\"].get(\"severity\")})" for x in a) or "  none")'
