"""Rule-based explainer: knows every failure mode of the SentinelOps pipeline.
Used on its own when no API key is set, and as hints for the LLM otherwise."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Finding:
    rule: str
    title: str
    cause: str
    fix: list[str]
    evidence: list[str] = field(default_factory=list)


@dataclass
class Rule:
    id: str
    pattern: re.Pattern[str]
    title: str
    cause: str
    fix: list[str]


RULES: list[Rule] = [
    Rule(
        "secret-leak",
        re.compile(r"leaks found|WRN \d+ leaks? found|\bleaks found:", re.I),
        "A secret was committed to the repository (gitleaks)",
        "gitleaks found credentials in the code or git history, so the pipeline stopped before anything was built.",
        [
            "Remove the secret from the code and load it from .env / Jenkins credentials instead.",
            "Rotate the exposed credential: it is in git history even after deletion.",
            "If it is a reviewed false positive, add its fingerprint to .gitleaksignore with a reason.",
        ],
    ),
    Rule(
        "unit-tests",
        re.compile(r"^FAILED .*::|=+ \d+ failed", re.M),
        "Unit tests failed",
        "One or more pytest tests failed in stage 2.",
        ["Run `make test` locally and fix the failing tests listed in the evidence."],
    ),
    Rule(
        "coverage",
        re.compile(r"FAIL Required test coverage of \d+% not reached", re.I),
        "Test coverage is below the 80 % gate",
        "pytest-cov reported coverage under the required threshold.",
        ["Add tests for the new code paths (`make test` shows the missing lines)."],
    ),
    Rule(
        "quality-gate",
        re.compile(r"SonarQube quality gate: (ERROR|FAILED|WARN)", re.I),
        "SonarQube quality gate failed",
        "The SentinelOps Gate requires coverage >= 80 %, A security/reliability ratings and 0 vulnerabilities.",
        [
            "Open the project in SonarQube (link in the stage log) and fix the failing conditions."
        ],
    ),
    Rule(
        "trivy-gate",
        re.compile(r"Trivy gate failed: (\d+) fixable CRITICAL", re.I),
        "Image has fixable CRITICAL vulnerabilities (Trivy gate)",
        "Trivy found CRITICAL CVEs that already have a patched version, so shipping them is avoidable risk.",
        [
            "Upgrade the packages listed in the evidence (app/requirements.txt or the base image tag).",
            "Rebuild; the gate passes once no fixable CRITICAL remains.",
        ],
    ),
    Rule(
        "drs-block",
        re.compile(r"blocked by the Deployment Risk Score", re.I),
        "Deployment Risk Score above the block threshold",
        "The combined residual risk (vulnerabilities, IaC findings, Sonar issues, coverage) exceeded 60/100.",
        ["Reduce the top factors shown in drs.md (largest points first)."],
    ),
    Rule(
        "admission-denied",
        re.compile(r"DEPLOY BLOCKED BY ADMISSION POLICY|denied the request", re.I),
        "Kubernetes admission (Kyverno) rejected the release",
        "The image or pod spec violated a SentinelOps policy: signature, scan/SBOM attestation, trusted registry/digest "
        "or pod security.",
        [
            "Check that stage 10 signed and attested the image (COSIGN_KEY_B64 set in .env).",
            "The denial message in the evidence names the exact policy and rule.",
        ],
    ),
    Rule(
        "canary-failed",
        re.compile(r"CANARY FAILED", re.I),
        "Canary failed its SLO analysis and was rolled back",
        "Prometheus showed the new revision above 5 % errors or 300 ms p95; Argo Rollouts restored the stable version.",
        [
            "`kubectl -n sentinelops describe analysisrun` shows which metric failed.",
            "Check for fault-injection settings (FAULT_ERROR_RATE / FAULT_LATENCY_MS) or a real regression.",
        ],
    ),
    Rule(
        "chaos-failed",
        re.compile(r"CHAOS GATE FAILED", re.I),
        "Chaos gate failed: the service did not self-heal fast enough",
        "After deleting pods / stressing CPU, recovery exceeded the limit or too many probes failed.",
        [
            "See chaos.json for recovery time and probe success; check readiness probes and resource limits."
        ],
    ),
    Rule(
        "smoke-failed",
        re.compile(r"SMOKE FAIL", re.I),
        "Post-deploy smoke test failed",
        "The deployed service did not answer an expected endpoint.",
        [
            "The failing endpoint is named in the evidence; check pod logs: `kubectl -n sentinelops logs -l "
            "app.kubernetes.io/name=sentinelops-app`."
        ],
    ),
    Rule(
        "no-cluster",
        re.compile(r"no Kubernetes API reachable|Kubernetes cluster unreachable", re.I),
        "Jenkins cannot reach the Kubernetes cluster",
        "The kubeconfig is missing or the kind cluster is stopped.",
        ["Run `make local-up` (or `make jenkins-kubeconfig`) on the laptop."],
    ),
    Rule(
        "docker-socket",
        re.compile(
            r"Cannot connect to the Docker daemon|permission denied.*docker\.sock", re.I
        ),
        "Jenkins cannot use Docker",
        "The Docker socket is not mounted or not accessible to the jenkins user.",
        ["Restart the stack with `make local-up`; check Docker Desktop is running."],
    ),
    Rule(
        "network",
        re.compile(
            r"Could not resolve host|Temporary failure in name resolution|connection refused",
            re.I,
        ),
        "Network/DNS failure reaching a dependency",
        "A service the stage needs was not reachable.",
        ["Check the host named in the evidence is running (`make local-status`)."],
    ),
    Rule(
        "dependency",
        re.compile(r"No matching distribution found|ResolutionImpossible", re.I),
        "Python dependency could not be installed",
        "A pinned package version is unavailable or conflicts.",
        ["Check the pins in app/requirements*.txt."],
    ),
]

GENERIC = Finding(
    "generic",
    "Build step failed",
    "A step exited with a non-zero code; no specific SentinelOps rule matched.",
    ["Read the last error lines in the evidence and the stage log in Jenkins."],
)


def _evidence(
    log: str, pattern: re.Pattern[str], context: int = 2, limit: int = 6
) -> list[str]:
    lines = log.splitlines()
    out: list[str] = []
    for i, line in enumerate(lines):
        if pattern.search(line):
            out.extend(lines[max(0, i - context) : i + context + 1])
            if len(out) >= limit:
                break
    return [ln.strip() for ln in out[:limit]]


def _trivy_details(reports: Path) -> list[str]:
    details = []
    for name in ("trivy-image.json", "trivy-fs.json"):
        try:
            doc = json.loads((reports / name).read_text())
        except (OSError, ValueError):
            continue
        for res in doc.get("Results") or []:
            for v in res.get("Vulnerabilities") or []:
                if v.get("Severity") == "CRITICAL" and v.get("FixedVersion"):
                    details.append(
                        f"{v['VulnerabilityID']}: {v.get('PkgName')} {v.get('InstalledVersion')} -> "
                        f"{v['FixedVersion']}"
                    )
    return details[:8]


def _drs_details(reports: Path) -> list[str]:
    try:
        drs = json.loads((reports / "drs.json").read_text())
    except (OSError, ValueError):
        return []
    top = sorted(drs.get("components", []), key=lambda c: -c["points"])[:4]
    return [
        f"DRS {drs['score']}: "
        + ", ".join(f"{c['name']}={c['points']}" for c in top if c["points"])
    ]


SKIP_MARKER = "skipped due to earlier failure"
NOISE = re.compile(r"^\s*(\[[^\]]*\]\s*)?(\[Pipeline\]|Post stage|$)")
SIGNALS = re.compile(r"error|fail|exception|exit code|killed|timed? ?out", re.I)


def _failing_stage_tail(log: str, limit: int = 6) -> list[str]:
    """Evidence for unmatched failures: error-like lines, ignoring the 'skipped due to
    earlier failure' lines Jenkins prints for later stages; otherwise the last real
    output of the stage that failed (everything before the first skip marker)."""
    lines = log.splitlines()
    cut = next((i for i, ln in enumerate(lines) if SKIP_MARKER in ln), len(lines))
    body = [ln.strip() for ln in lines[:cut] if not NOISE.match(ln)]
    hits = [ln for ln in body if SIGNALS.search(ln)]
    return (hits or body)[-limit:]


def analyse(log: str, stage: str = "", reports: Path | None = None) -> list[Finding]:
    findings: list[Finding] = []
    for rule in RULES:
        if rule.pattern.search(log):
            ev = _evidence(log, rule.pattern)
            if reports is not None and rule.id == "trivy-gate":
                ev += _trivy_details(reports)
            if reports is not None and rule.id == "drs-block":
                ev += _drs_details(reports)
            findings.append(Finding(rule.id, rule.title, rule.cause, rule.fix, ev))
    if not findings:
        tail = _failing_stage_tail(log)
        findings.append(
            Finding(
                GENERIC.rule,
                GENERIC.title + (f" in {stage}" if stage else ""),
                GENERIC.cause,
                GENERIC.fix,
                tail,
            )
        )
    return findings
