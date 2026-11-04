"""Grafana dashboards as code.

Dashboards are declared compactly here and compiled to Grafana JSON in
monitoring/grafana/dashboards/. scripts/monitoring-apply.sh ships each file as a
ConfigMap labelled grafana_dashboard=1, which the Grafana sidecar loads automatically.

  python3 -m tools.monitoring.dashboards            # regenerate JSON
  python3 -m tools.monitoring.dashboards --check    # fail if JSON is stale (used by tests)
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parents[2] / "monitoring" / "grafana" / "dashboards"
DS = {"type": "prometheus", "uid": "prometheus"}
NS = 'namespace="sentinelops"'
PIPE = 'job="sentinelops_pipeline"'


@dataclass
class Panel:
    title: str
    kind: str  # stat | timeseries | gauge | table | text
    targets: list[tuple[str, str]] = field(default_factory=list)  # (expr, legend)
    w: int = 6
    h: int = 4
    unit: str = "short"
    description: str = ""
    thresholds: list[tuple[float | None, str]] | None = None
    decimals: int | None = None
    min: float | None = None
    max: float | None = None
    content: str = ""  # text panels


@dataclass
class Row:
    title: str
    panels: list[Panel]


@dataclass
class Dashboard:
    uid: str
    title: str
    description: str
    rows: list[Row]
    tags: list[str] = field(default_factory=lambda: ["sentinelops"])
    refresh: str = "30s"
    time_from: str = "now-3h"


GREEN_RED = [(None, "green"), (1, "red")]


def _panel_json(p: Panel, pid: int, x: int, y: int) -> dict:
    base: dict = {
        "id": pid,
        "type": p.kind,
        "title": p.title,
        "description": p.description,
        "gridPos": {"h": p.h, "w": p.w, "x": x, "y": y},
    }
    if p.kind == "text":
        base["options"] = {"mode": "markdown", "content": p.content}
        return base
    base["datasource"] = DS
    base["targets"] = [
        {
            "refId": chr(ord("A") + i),
            "datasource": DS,
            "expr": expr,
            "legendFormat": legend,
            "range": True,
        }
        for i, (expr, legend) in enumerate(p.targets)
    ]
    defaults: dict = {"unit": p.unit}
    if p.decimals is not None:
        defaults["decimals"] = p.decimals
    if p.min is not None:
        defaults["min"] = p.min
    if p.max is not None:
        defaults["max"] = p.max
    if p.thresholds:
        defaults["thresholds"] = {
            "mode": "absolute",
            "steps": [{"value": v, "color": c} for v, c in p.thresholds],
        }
        defaults["color"] = {"mode": "thresholds"}
    if p.kind == "timeseries":
        defaults["custom"] = {"lineWidth": 2, "fillOpacity": 10, "showPoints": "never"}
        if p.thresholds:
            defaults["custom"]["thresholdsStyle"] = {"mode": "line+area"}
    base["fieldConfig"] = {"defaults": defaults, "overrides": []}
    if p.kind == "stat":
        base["options"] = {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "background" if p.thresholds else "value",
            "graphMode": "area",
            "textMode": "auto",
        }
    elif p.kind == "gauge":
        base["options"] = {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}
        }
    elif p.kind == "timeseries":
        base["options"] = {
            "legend": {"displayMode": "list", "placement": "bottom"},
            "tooltip": {"mode": "multi"},
        }
    elif p.kind == "table":
        base["options"] = {"showHeader": True}
        for t in base["targets"]:
            t["format"] = "table"
            t["instant"] = True
            t["range"] = False
    return base


def compile_dashboard(d: Dashboard) -> dict:
    panels: list[dict] = []
    pid, y = 1, 0
    for row in d.rows:
        panels.append(
            {
                "id": pid,
                "type": "row",
                "title": row.title,
                "collapsed": False,
                "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
                "panels": [],
            }
        )
        pid += 1
        y += 1
        x, row_h = 0, 0
        for p in row.panels:
            if x + p.w > 24:
                x, y = 0, y + row_h
                row_h = 0
            panels.append(_panel_json(p, pid, x, y))
            pid += 1
            x += p.w
            row_h = max(row_h, p.h)
        y += row_h
    return {
        "uid": d.uid,
        "title": d.title,
        "description": d.description,
        "tags": d.tags,
        "timezone": "browser",
        "editable": True,
        "graphTooltip": 1,
        "refresh": d.refresh,
        "schemaVersion": 39,
        "version": 1,
        "time": {"from": d.time_from, "to": "now"},
        "templating": {"list": []},
        "annotations": {"list": []},
        "links": [
            {
                "title": "SentinelOps dashboards",
                "type": "dashboards",
                "tags": ["sentinelops"],
                "asDropdown": True,
            }
        ],
        "panels": panels,
    }


def dashboards() -> list[Dashboard]:
    api = f'{NS},path=~"/api/.*"'
    slo = Dashboard(
        uid="sentinelops-slo",
        title="SentinelOps · Service SLO",
        description="Availability and latency SLOs, error budget and burn rate for sentinelops-app (/api traffic only).",
        rows=[
            Row(
                "SLO summary",
                [
                    Panel(
                        "Availability (5m)",
                        "stat",
                        [("1 - sentinelops:http_errors:ratio_rate5m", "")],
                        unit="percentunit",
                        decimals=2,
                        thresholds=[(None, "red"), (0.99, "green")],
                    ),
                    Panel(
                        "p95 latency (5m)",
                        "stat",
                        [("sentinelops:http_latency_seconds:p95_5m", "")],
                        unit="s",
                        decimals=3,
                        thresholds=[(None, "green"), (0.3, "red")],
                    ),
                    Panel(
                        "Error budget remaining (7d)",
                        "gauge",
                        [("sentinelops:error_budget:remaining_ratio", "")],
                        unit="percentunit",
                        min=0,
                        max=1,
                        thresholds=[(None, "red"), (0.25, "orange"), (0.5, "green")],
                    ),
                    Panel(
                        "Burn rate (1h)",
                        "stat",
                        [("sentinelops:error_budget:burn_rate1h", "")],
                        unit="x",
                        decimals=1,
                        thresholds=[(None, "green"), (6, "orange"), (14.4, "red")],
                        description="1 = spending the budget exactly over the SLO period; 14.4 pages.",
                    ),
                ],
            ),
            Row(
                "Traffic and errors",
                [
                    Panel(
                        "Requests per second by status",
                        "timeseries",
                        [
                            (
                                f"sum by (status) (rate(http_requests_total{{{api}}}[1m]))",
                                "{{status}}",
                            )
                        ],
                        w=12,
                        h=8,
                        unit="reqps",
                    ),
                    Panel(
                        "Error ratio vs SLO (1 %)",
                        "timeseries",
                        [
                            ("sentinelops:http_errors:ratio_rate5m", "5m error ratio"),
                            ("sentinelops:http_errors:ratio_rate1h", "1h error ratio"),
                        ],
                        w=12,
                        h=8,
                        unit="percentunit",
                        thresholds=[(None, "green"), (0.01, "red")],
                    ),
                    Panel(
                        "p95 latency vs SLO (300 ms)",
                        "timeseries",
                        [("sentinelops:http_latency_seconds:p95_5m", "p95")],
                        w=12,
                        h=8,
                        unit="s",
                        thresholds=[(None, "green"), (0.3, "red")],
                    ),
                    Panel(
                        "Error ratio: canary vs stable",
                        "timeseries",
                        [
                            (
                                "sentinelops:http_errors:ratio_rate1m_by_role",
                                "{{role}} {{rollouts_pod_template_hash}}",
                            )
                        ],
                        w=12,
                        h=8,
                        unit="percentunit",
                        description="Per Argo Rollouts revision; the canary analysis aborts above 5 %.",
                    ),
                ],
            ),
        ],
    )

    delivery = Dashboard(
        uid="sentinelops-delivery",
        title="SentinelOps · Delivery & Supply Chain",
        description="Pipeline health, DORA metrics (approximations from pipeline events), vulnerabilities, canary and admission control.",
        time_from="now-7d",
        rows=[
            Row(
                "DORA (last 7 days)",
                [
                    Panel(
                        "Deployments / day",
                        "stat",
                        [("sentinelops:deployments:per_day7d", "")],
                        w=4,
                        decimals=2,
                    ),
                    Panel(
                        "Lead time for changes (avg)",
                        "stat",
                        [("sentinelops:lead_time_seconds:avg7d", "")],
                        w=5,
                        unit="s",
                    ),
                    Panel(
                        "Change failure rate",
                        "stat",
                        [("sentinelops:change_failure_rate:ratio7d", "")],
                        w=5,
                        unit="percentunit",
                        thresholds=[(None, "green"), (0.15, "orange"), (0.3, "red")],
                    ),
                    Panel(
                        "Time to restore (last)",
                        "stat",
                        [("sentinelops:time_to_restore_seconds:last", "")],
                        w=5,
                        unit="s",
                    ),
                    Panel(
                        "Last build",
                        "stat",
                        [
                            (
                                f'max(sentinelops_build_success{{{PIPE},branch="main"}})',
                                "",
                            )
                        ],
                        w=5,
                        thresholds=[(None, "red"), (1, "green")],
                        description="1 = green, 0 = red (main).",
                    ),
                ],
            ),
            Row(
                "Security gates",
                [
                    Panel(
                        "Vulnerabilities by severity (latest image)",
                        "timeseries",
                        [
                            (
                                f"max(sentinelops_vulnerabilities_critical{{{PIPE}}})",
                                "critical",
                            ),
                            (
                                f"max(sentinelops_vulnerabilities_high{{{PIPE}}})",
                                "high",
                            ),
                            (
                                f"max(sentinelops_vulnerabilities_medium{{{PIPE}}})",
                                "medium",
                            ),
                            (f"max(sentinelops_vulnerabilities_low{{{PIPE}}})", "low"),
                        ],
                        w=12,
                        h=8,
                    ),
                    Panel(
                        "Deployment Risk Score",
                        "timeseries",
                        [
                            (
                                f"max by (branch) (sentinelops_drs_score{{{PIPE}}})",
                                "{{branch}}",
                            )
                        ],
                        w=12,
                        h=8,
                        min=0,
                        max=100,
                        thresholds=[(None, "green"), (30, "orange"), (60, "red")],
                        description="< 30 auto-deploy, 30-60 canary + extra analysis, > 60 blocked (Feature 1).",
                    ),
                    Panel(
                        "Admission requests (sentinelops ns)",
                        "timeseries",
                        [
                            (
                                'sum by (request_allowed) (increase(kyverno_admission_requests_total{resource_namespace="sentinelops"}[5m]))',
                                "allowed={{request_allowed}}",
                            ),
                        ],
                        w=12,
                        h=8,
                        description="Kyverno decisions; allowed=false are blocked unsigned/unscanned/non-compliant pods.",
                    ),
                    Panel(
                        "Build duration",
                        "timeseries",
                        [
                            (
                                f"max by (branch) (sentinelops_build_duration_seconds{{{PIPE}}})",
                                "{{branch}}",
                            )
                        ],
                        w=12,
                        h=8,
                        unit="s",
                    ),
                ],
            ),
            Row(
                "Progressive delivery",
                [
                    Panel(
                        "Rollout phase",
                        "table",
                        [("max by (name, phase) (rollout_info{" + NS + "})", "")],
                        w=8,
                        h=6,
                    ),
                    Panel(
                        "Analysis runs",
                        "table",
                        [("max by (name, phase) (analysis_run_info{" + NS + "})", "")],
                        w=8,
                        h=6,
                    ),
                    Panel(
                        "Ready app pods",
                        "stat",
                        [(f'sum(kube_pod_status_ready{{{NS},condition="true"}})', "")],
                        w=8,
                        h=6,
                    ),
                ],
            ),
        ],
    )

    cluster = Dashboard(
        uid="sentinelops-cluster",
        title="SentinelOps · Cluster Health",
        description="Node and workload health from node-exporter, kube-state-metrics and cAdvisor.",
        rows=[
            Row(
                "Node",
                [
                    Panel(
                        "Node CPU busy",
                        "gauge",
                        [
                            (
                                '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))',
                                "",
                            )
                        ],
                        unit="percentunit",
                        min=0,
                        max=1,
                        thresholds=[(None, "green"), (0.7, "orange"), (0.9, "red")],
                    ),
                    Panel(
                        "Node memory used",
                        "gauge",
                        [
                            (
                                "1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)",
                                "",
                            )
                        ],
                        unit="percentunit",
                        min=0,
                        max=1,
                        thresholds=[(None, "green"), (0.75, "orange"), (0.9, "red")],
                    ),
                    Panel(
                        "Pods not ready (all namespaces)",
                        "stat",
                        [
                            (
                                'sum(kube_pod_status_ready{condition="false"}) or vector(0)',
                                "",
                            )
                        ],
                        thresholds=[(None, "green"), (1, "red")],
                    ),
                    Panel(
                        "Container restarts (1h)",
                        "stat",
                        [
                            (
                                "sum(increase(kube_pod_container_status_restarts_total[1h])) or vector(0)",
                                "",
                            )
                        ],
                        decimals=0,
                        thresholds=[(None, "green"), (1, "orange"), (5, "red")],
                    ),
                ],
            ),
            Row(
                "Workloads",
                [
                    Panel(
                        "CPU by namespace",
                        "timeseries",
                        [
                            (
                                'sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))',
                                "{{namespace}}",
                            )
                        ],
                        w=12,
                        h=8,
                        unit="cores",
                    ),
                    Panel(
                        "Memory by namespace",
                        "timeseries",
                        [
                            (
                                'sum by (namespace) (container_memory_working_set_bytes{container!=""})',
                                "{{namespace}}",
                            )
                        ],
                        w=12,
                        h=8,
                        unit="bytes",
                    ),
                    Panel(
                        "sentinelops-app memory per pod",
                        "timeseries",
                        [
                            (
                                f'sum by (pod) (container_memory_working_set_bytes{{{NS},container="app"}})',
                                "{{pod}}",
                            )
                        ],
                        w=12,
                        h=8,
                        unit="bytes",
                    ),
                    Panel(
                        "Restarts by pod (1h)",
                        "table",
                        [
                            (
                                "topk(10, sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0)",
                                "",
                            )
                        ],
                        w=12,
                        h=8,
                    ),
                ],
            ),
        ],
    )
    return [slo, delivery, cluster]


def render_all() -> dict[str, str]:
    return {
        f"{d.uid}.json": json.dumps(compile_dashboard(d), indent=2) + "\n"
        for d in dashboards()
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if committed JSON differs from the generator",
    )
    args = parser.parse_args(argv)
    rendered = render_all()
    if args.check:
        stale = [
            n
            for n, txt in rendered.items()
            if not (OUT_DIR / n).exists() or (OUT_DIR / n).read_text() != txt
        ]
        if stale:
            print(
                "stale dashboards (run python3 -m tools.monitoring.dashboards): "
                + ", ".join(stale)
            )
            return 1
        print(f"{len(rendered)} dashboards up to date")
        return 0
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, txt in rendered.items():
        (OUT_DIR / name).write_text(txt)
        print(f"wrote {OUT_DIR / name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
