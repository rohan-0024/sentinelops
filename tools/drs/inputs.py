"""Parsers that turn scanner reports into counts. Each returns None when its report is
missing or unreadable, so the scorer can apply an explicit 'unknown risk' penalty."""

from __future__ import annotations

import json
import xml.etree.ElementTree as ET  # noqa: S405 - parses our own coverage.xml
from pathlib import Path


def _load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def trivy(reports: Path) -> dict[str, int] | None:
    """Counts from trivy-image.json + trivy-fs.json (deduplicated by CVE+package)."""
    files = [reports / "trivy-image.json", reports / "trivy-fs.json"]
    docs = [
        d for d in (_load_json(f) for f in files if f.exists()) if isinstance(d, dict)
    ]
    if not docs:
        return None
    seen: set[tuple[str, str, str]] = set()
    counts = {
        "critical_fixable": 0,
        "critical_unfixed": 0,
        "high_fixable": 0,
        "high_unfixed": 0,
        "medium": 0,
    }
    for doc in docs:
        for result in doc.get("Results") or []:
            for v in result.get("Vulnerabilities") or []:
                key = (
                    v.get("VulnerabilityID", ""),
                    v.get("PkgName", ""),
                    v.get("InstalledVersion", ""),
                )
                if key in seen:
                    continue
                seen.add(key)
                sev = (v.get("Severity") or "").upper()
                fixed = bool(v.get("FixedVersion"))
                if sev == "CRITICAL":
                    counts["critical_fixable" if fixed else "critical_unfixed"] += 1
                elif sev == "HIGH":
                    counts["high_fixable" if fixed else "high_unfixed"] += 1
                elif sev == "MEDIUM":
                    counts["medium"] += 1
    return counts


def gitleaks(reports: Path) -> dict[str, int] | None:
    doc = _load_json(reports / "gitleaks.json")
    if doc is None:
        return None
    return {"secrets": len(doc) if isinstance(doc, list) else 0}


def checkov(reports: Path) -> dict[str, int] | None:
    """checkov -o json writes one object per framework, or a list of them."""
    doc = _load_json(reports / "results_json.json")
    if doc is None:
        return None
    runs = doc if isinstance(doc, list) else [doc]
    failed = 0
    for run in runs:
        if not isinstance(run, dict):
            continue
        summary = run.get("summary") or {}
        if "failed" in summary:
            failed += int(summary["failed"])
        else:
            failed += len((run.get("results") or {}).get("failed_checks") or [])
    return {"failed": failed}


def sonar(reports: Path) -> dict[str, float] | None:
    doc = _load_json(reports / "sonar-measures.json")
    if not isinstance(doc, dict):
        return None
    measures = (doc.get("component") or {}).get("measures") or []
    values: dict[str, float] = {}
    for m in measures:
        try:
            values[m["metric"]] = float(m["value"])
        except (KeyError, TypeError, ValueError):
            continue
    return values


def coverage(reports: Path) -> dict[str, float] | None:
    """Line coverage percentage from a Cobertura coverage.xml."""
    path = reports / "coverage.xml"
    if not path.exists():
        return None
    try:
        root = ET.parse(path).getroot()  # noqa: S314 - trusted, produced by our own test stage
        return {"percent": round(float(root.attrib["line-rate"]) * 100, 2)}
    except (ET.ParseError, KeyError, ValueError):
        return None
