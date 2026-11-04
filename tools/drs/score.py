"""Transparent weighted Deployment Risk Score."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path

import yaml

from . import inputs


@dataclass
class Component:
    name: str
    source: str
    raw: float
    weight: float
    cap: float
    points: float
    help: str = ""


@dataclass
class Result:
    score: float
    decision: str  # auto | canary | block
    thresholds: dict
    components: list[Component] = field(default_factory=list)
    missing: dict[str, float] = field(default_factory=dict)
    inputs: dict[str, dict | None] = field(default_factory=dict)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["score"] = round(self.score, 1)
        return d


def load_config(path: Path) -> dict:
    cfg = yaml.safe_load(path.read_text())
    th = cfg["thresholds"]
    if not 0 <= th["auto"] <= th["block"] <= 100:
        raise ValueError("thresholds must satisfy 0 <= auto <= block <= 100")
    return cfg


def decide(score: float, thresholds: dict) -> str:
    if score < thresholds["auto"]:
        return "auto"
    if score <= thresholds["block"]:
        return "canary"
    return "block"


def collect(reports: Path) -> dict[str, dict | None]:
    return {
        "trivy": inputs.trivy(reports),
        "gitleaks": inputs.gitleaks(reports),
        "checkov": inputs.checkov(reports),
        "sonar": inputs.sonar(reports),
        "coverage": inputs.coverage(reports),
    }


def raw_values(data: dict[str, dict | None], factors: dict) -> dict[str, float | None]:
    t, g, c, s, cov = (
        data.get(k) for k in ("trivy", "gitleaks", "checkov", "sonar", "coverage")
    )
    target = float(factors.get("coverage_gap", {}).get("target", 80))
    return {
        "vuln_critical_unfixed": None if t is None else t["critical_unfixed"],
        "vuln_high_fixable": None if t is None else t["high_fixable"],
        "vuln_high_unfixed": None if t is None else t["high_unfixed"],
        "vuln_medium": None if t is None else t["medium"],
        "secrets": None if g is None else g["secrets"],
        "iac_failed_checks": None if c is None else c["failed"],
        "sonar_vulnerabilities": None if s is None else s.get("vulnerabilities", 0.0),
        "sonar_bugs": None if s is None else s.get("bugs", 0.0),
        "sonar_security_hotspots": None
        if s is None
        else s.get("security_hotspots", 0.0),
        "sonar_code_smells": None if s is None else s.get("code_smells", 0.0),
        "coverage_gap": None if cov is None else max(0.0, target - cov["percent"]),
    }


def compute(data: dict[str, dict | None], cfg: dict) -> Result:
    factors = cfg["factors"]
    raws = raw_values(data, factors)
    components: list[Component] = []
    for name, spec in factors.items():
        raw = raws.get(name)
        if raw is None:
            continue  # source missing: handled by the missing-input penalty
        points = min(float(spec["cap"]), float(spec["weight"]) * float(raw))
        components.append(
            Component(
                name,
                spec["source"],
                float(raw),
                float(spec["weight"]),
                float(spec["cap"]),
                round(points, 2),
                spec.get("help", ""),
            )
        )
    missing = {
        src: float(p)
        for src, p in cfg.get("missing_input_penalty", {}).items()
        if data.get(src) is None
    }
    score = min(100.0, sum(c.points for c in components) + sum(missing.values()))
    return Result(
        score,
        decide(score, cfg["thresholds"]),
        cfg["thresholds"],
        components,
        missing,
        data,
    )


def markdown(result: Result) -> str:
    th = result.thresholds
    icon = {"auto": "🟢", "canary": "🟡", "block": "🔴"}[result.decision]
    lines = [
        f"## Deployment Risk Score: **{result.score:.1f} / 100** {icon} `{result.decision}`",
        "",
        f"Decision rule: < {th['auto']} auto-deploy · {th['auto']}-{th['block']} canary with extra analysis · "
        f"> {th['block']} blocked",
        "",
        "| Factor | Source | Count | Weight | Cap | Points |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for c in sorted(result.components, key=lambda c: -c.points):
        lines.append(
            f"| {c.help or c.name} | {c.source} | {c.raw:g} | {c.weight:g} | {c.cap:g} | {c.points:g} |"
        )
    for src, pts in result.missing.items():
        lines.append(f"| report missing (unknown risk) | {src} | - | - | - | {pts:g} |")
    lines += ["", f"Total = min(100, Σ points) = **{result.score:.1f}**", ""]
    return "\n".join(lines)


def prometheus_text(result: Result) -> str:
    out = [
        "# HELP sentinelops_drs_score Deployment Risk Score (0-100)",
        "# TYPE sentinelops_drs_score gauge",
        f"sentinelops_drs_score {result.score:.1f}",
        "# HELP sentinelops_drs_component_points Points contributed by each DRS factor",
        "# TYPE sentinelops_drs_component_points gauge",
    ]
    out += [
        f'sentinelops_drs_component_points{{factor="{c.name}"}} {c.points:g}'
        for c in result.components
    ]
    return "\n".join(out) + "\n"
