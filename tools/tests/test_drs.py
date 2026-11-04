import json
from pathlib import Path

import pytest

from tools.drs.__main__ import main
from tools.drs.score import collect, compute, decide, load_config

CONFIG = Path(__file__).resolve().parents[2] / "policy" / "risk.yaml"


def vuln(vid, sev, fixed=""):
    return {
        "VulnerabilityID": vid,
        "PkgName": "pkg",
        "InstalledVersion": "1",
        "Severity": sev,
        "FixedVersion": fixed,
    }


def write_reports(
    d: Path,
    *,
    vulns=(),
    fs_vulns=(),
    secrets=0,
    checkov_failed=0,
    sonar=None,
    coverage=0.95,
    skip=(),
):
    if "trivy" not in skip:
        (d / "trivy-image.json").write_text(
            json.dumps({"Results": [{"Vulnerabilities": list(vulns)}]})
        )
        (d / "trivy-fs.json").write_text(
            json.dumps({"Results": [{"Vulnerabilities": list(fs_vulns)}]})
        )
    if "gitleaks" not in skip:
        (d / "gitleaks.json").write_text(json.dumps([{"RuleID": "x"}] * secrets))
    if "checkov" not in skip:
        (d / "results_json.json").write_text(
            json.dumps(
                [
                    {"check_type": "terraform", "summary": {"failed": checkov_failed}},
                    {"check_type": "dockerfile", "summary": {"failed": 0}},
                ]
            )
        )
    if "sonar" not in skip:
        measures = [{"metric": k, "value": str(v)} for k, v in (sonar or {}).items()]
        (d / "sonar-measures.json").write_text(
            json.dumps({"component": {"measures": measures}})
        )
    if "coverage" not in skip:
        (d / "coverage.xml").write_text(
            f'<?xml version="1.0" ?><coverage line-rate="{coverage}"></coverage>'
        )
    return d


@pytest.fixture
def cfg():
    return load_config(CONFIG)


def score_of(d, cfg):
    return compute(collect(d), cfg)


def test_clean_build_scores_zero_and_auto_deploys(tmp_path, cfg):
    r = score_of(write_reports(tmp_path), cfg)
    assert r.score == 0 and r.decision == "auto" and r.missing == {}


def test_typical_distroless_residue_stays_auto(tmp_path, cfg):
    vulns = [vuln("C1", "CRITICAL"), vuln("H1", "HIGH"), vuln("H2", "HIGH")] + [
        vuln(f"M{i}", "MEDIUM") for i in range(10)
    ]
    r = score_of(write_reports(tmp_path, vulns=vulns), cfg)
    # 8 (unfixed critical) + 2 (unfixed highs) + 2 (10 mediums x 0.2) = 12
    assert r.score == pytest.approx(12) and r.decision == "auto"


def test_fixable_highs_and_iac_findings_push_into_canary(tmp_path, cfg):
    vulns = [vuln(f"H{i}", "HIGH", fixed="2.0") for i in range(5)]
    r = score_of(write_reports(tmp_path, vulns=vulns, checkov_failed=5), cfg)
    # 5 x 3 = 15 ; 5 x 2 = 10  -> 25 ... + coverage 0 -> still auto; add sonar bug -> canary
    assert r.score == pytest.approx(25) and r.decision == "auto"
    r2 = score_of(
        write_reports(tmp_path, vulns=vulns, checkov_failed=5, sonar={"bugs": 2}), cfg
    )
    assert r2.score == pytest.approx(31) and r2.decision == "canary"


def test_caps_limit_each_factor(tmp_path, cfg):
    vulns = [vuln(f"H{i}", "HIGH", fixed="2") for i in range(100)]
    r = score_of(write_reports(tmp_path, vulns=vulns), cfg)
    comp = {c.name: c for c in r.components}
    assert (
        comp["vuln_high_fixable"].raw == 100 and comp["vuln_high_fixable"].points == 24
    )


def test_duplicate_cves_across_image_and_fs_count_once(tmp_path, cfg):
    v = vuln("H1", "HIGH", fixed="2")
    r = score_of(write_reports(tmp_path, vulns=[v], fs_vulns=[v]), cfg)
    assert {c.name: c.raw for c in r.components}["vuln_high_fixable"] == 1


def test_any_secret_blocks(tmp_path, cfg):
    r = score_of(write_reports(tmp_path, secrets=1), cfg)
    assert r.score == 100 and r.decision == "block"


def test_accumulated_residual_risk_blocks(tmp_path, cfg):
    common = dict(checkov_failed=10, sonar={"vulnerabilities": 3, "bugs": 1})
    r = score_of(write_reports(tmp_path, **common), cfg)
    assert r.score == pytest.approx(53) and r.decision == "canary"  # 20 + 30 + 3
    r2 = score_of(
        write_reports(
            tmp_path, vulns=[vuln("C1", "CRITICAL"), vuln("C2", "CRITICAL")], **common
        ),
        cfg,
    )
    assert r2.score == pytest.approx(69) and r2.decision == "block"  # + 2 x 8


def test_score_never_exceeds_100(tmp_path, cfg):
    vulns = [vuln(f"C{i}", "CRITICAL") for i in range(9)] + [
        vuln(f"H{i}", "HIGH", "2") for i in range(9)
    ]
    r = score_of(
        write_reports(
            tmp_path,
            vulns=vulns,
            secrets=3,
            checkov_failed=50,
            sonar={"vulnerabilities": 5, "bugs": 9},
            coverage=0.1,
        ),
        cfg,
    )
    assert r.score == 100 and r.decision == "block"


def test_low_coverage_adds_gap_points(tmp_path, cfg):
    r = score_of(write_reports(tmp_path, coverage=0.60), cfg)
    assert {c.name: c.points for c in r.components}["coverage_gap"] == pytest.approx(10)


def test_missing_reports_are_unknown_risk_not_zero(tmp_path, cfg):
    r = score_of(write_reports(tmp_path, skip=("trivy", "coverage")), cfg)
    assert r.missing == {"trivy": 15, "coverage": 10} and r.score == 25


def test_decision_boundaries(cfg):
    th = cfg["thresholds"]
    assert decide(29.9, th) == "auto" and decide(30, th) == "canary"
    assert decide(60, th) == "canary" and decide(60.1, th) == "block"


def test_invalid_thresholds_rejected(tmp_path):
    bad = tmp_path / "risk.yaml"
    bad.write_text("thresholds: {auto: 70, block: 30}\nfactors: {}\n")
    with pytest.raises(ValueError):
        load_config(bad)


def test_cli_writes_reports_and_exit_codes(tmp_path):
    reports = write_reports(
        tmp_path / "r" if (tmp_path / "r").mkdir() is None else tmp_path
    )
    assert (
        main(
            ["--reports", str(reports), "--config", str(CONFIG), "--out", str(reports)]
        )
        == 0
    )
    data = json.loads((reports / "drs.json").read_text())
    assert data["decision"] == "auto" and "components" in data
    assert "Deployment Risk Score" in (reports / "drs.md").read_text()
    assert "sentinelops_drs_score 0.0" in (reports / "drs.prom").read_text()
    write_reports(reports, secrets=2)
    assert (
        main(
            ["--reports", str(reports), "--config", str(CONFIG), "--out", str(reports)]
        )
        == 3
    )


def test_policy_file_is_valid(cfg):
    for name, spec in cfg["factors"].items():
        assert spec["weight"] > 0 and spec["cap"] > 0, name
        assert spec["source"] in cfg["missing_input_penalty"], name
