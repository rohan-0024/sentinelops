import json

from tools.monitoring.dashboards import (
    OUT_DIR,
    compile_dashboard,
    dashboards,
    main,
    render_all,
)


def all_compiled():
    return [compile_dashboard(d) for d in dashboards()]


def test_committed_json_matches_generator():
    assert main(["--check"]) == 0


def test_uids_and_titles_unique():
    ds = all_compiled()
    assert len({d["uid"] for d in ds}) == len(ds)
    assert len({d["title"] for d in ds}) == len(ds)


def test_panel_ids_unique_and_targets_valid():
    for d in all_compiled():
        ids = [p["id"] for p in d["panels"]]
        assert len(ids) == len(set(ids)), d["uid"]
        for p in d["panels"]:
            if p["type"] in ("row", "text"):
                continue
            assert p["datasource"] == {"type": "prometheus", "uid": "prometheus"}
            assert p["targets"], f"{d['uid']}:{p['title']} has no query"
            for t in p["targets"]:
                assert t["expr"].count("(") == t["expr"].count(")"), t["expr"]
                assert t["expr"].count("{") == t["expr"].count("}"), t["expr"]


def test_panels_do_not_overlap_and_fit_grid():
    for d in all_compiled():
        cells = set()
        for p in d["panels"]:
            g = p["gridPos"]
            assert 0 <= g["x"] and g["x"] + g["w"] <= 24, (d["uid"], p["title"])
            for x in range(g["x"], g["x"] + g["w"]):
                for y in range(g["y"], g["y"] + g["h"]):
                    assert (x, y) not in cells, (d["uid"], p["title"])
                    cells.add((x, y))


def by_uid(uid):
    return next(compile_dashboard(d) for d in dashboards() if d.uid == uid)


def test_command_center_covers_every_feature7_signal():
    exprs = " ".join(
        t["expr"]
        for p in by_uid("sentinelops-command-center")["panels"]
        for t in p.get("targets", [])
    )
    required = {
        "DORA deploy frequency": "deployments:per_day7d",
        "DORA lead time": "lead_time_seconds",
        "DORA change failure rate": "change_failure_rate",
        "DORA MTTR": "time_to_restore_seconds",
        "DRS trend": "sentinelops_drs_score",
        "vulnerabilities by severity": "sentinelops_vulnerabilities_critical",
        "canary status": "rollout_info",
        "chaos recovery time": "sentinelops_chaos_recovery_seconds",
        "SLO / error budget": "error_budget:remaining_ratio",
        "node health (node-exporter)": "node_cpu_seconds_total",
        "kube-state-metrics": "kube_pod_status_ready",
    }
    missing = [k for k, needle in required.items() if needle not in exprs]
    assert not missing, missing


def test_slo_dashboard_covers_required_signals():
    exprs = " ".join(
        t["expr"]
        for p in compile_dashboard(dashboards()[0])["panels"]
        for t in p.get("targets", [])
    )
    for needle in (
        "error_budget:remaining_ratio",
        "burn_rate1h",
        "p95_5m",
        "ratio_rate1m_by_role",
    ):
        assert needle in exprs


def test_rendered_files_are_valid_json():
    for name, text in render_all().items():
        assert json.loads(text)["uid"] + ".json" == name
    assert OUT_DIR.name == "dashboards"
