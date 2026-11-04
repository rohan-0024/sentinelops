"""Static checks for Prometheus rule files (promtool unit tests run via `make monitoring-test`)."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
RULE_FILES = sorted((ROOT / "monitoring" / "prometheus").glob("*.rules.yaml"))
RUNBOOK = (ROOT / "docs" / "RUNBOOK.md").read_text()
ANCHORS = set(re.findall(r"^## ([a-z0-9-]+)\s*$", RUNBOOK, flags=re.M))


def rules():
    for path in RULE_FILES:
        for group in yaml.safe_load(path.read_text())["groups"]:
            for rule in group["rules"]:
                yield path.name, group["name"], rule


def test_rule_files_exist():
    assert {p.name for p in RULE_FILES} == {
        "sentinelops-slo.rules.yaml",
        "sentinelops-delivery.rules.yaml",
    }


def test_every_alert_has_severity_summary_and_runbook():
    alerts = [r for _, _, r in rules() if "alert" in r]
    assert len(alerts) >= 10
    for r in alerts:
        assert r["labels"]["severity"] in {"critical", "warning", "info"}, r["alert"]
        assert r["annotations"]["summary"], r["alert"]
        runbook = r["annotations"]["runbook"]
        assert runbook.startswith("docs/RUNBOOK.md#"), r["alert"]
        assert (
            runbook.split("#", 1)[1] in ANCHORS
        ), f"{r['alert']}: missing runbook section"


def test_recording_rules_follow_naming_convention():
    for _, _, r in rules():
        if "record" in r:
            assert re.fullmatch(r"sentinelops:[a-z0-9_]+:[a-z0-9_]+", r["record"]), r[
                "record"
            ]


def test_names_unique():
    names = [r.get("alert") or r.get("record") for _, _, r in rules()]
    assert len(names) == len(set(names))


def test_slo_alerts_use_multiwindow_burn_rates():
    by_name = {r.get("alert"): r for _, _, r in rules() if "alert" in r}
    fast = by_name["SentinelOpsErrorBudgetFastBurn"]["expr"]
    slow = by_name["SentinelOpsErrorBudgetSlowBurn"]["expr"]
    assert "ratio_rate1h" in fast and "ratio_rate5m" in fast and "14.4" in fast
    assert "ratio_rate6h" in slow and "ratio_rate30m" in slow and "6 *" in slow


def test_promtool_tests_cover_both_rule_files():
    tested = set()
    for t in (ROOT / "monitoring" / "tests").glob("*.test.yaml"):
        for f in yaml.safe_load(t.read_text())["rule_files"]:
            tested.add(Path(f).name)
    assert tested == {p.name for p in RULE_FILES}
