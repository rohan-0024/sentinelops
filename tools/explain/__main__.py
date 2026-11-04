"""CLI: python3 -m tools.explain --log reports/build-log.txt --stage "6. Trivy..." --out reports

Writes explain.md / explain.json. Uses the Anthropic Messages API when ANTHROPIC_API_KEY is
set (model from ANTHROPIC_MODEL), else the rule engine. Always exits 0: explaining a failure
must never itself fail the build.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from dataclasses import asdict
from pathlib import Path

from .redact import redact
from .rules import Finding, analyse

API_URL = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = "claude-sonnet-5-5"
MAX_LOG_CHARS = 12_000

SYSTEM = (
    "You are a senior DevSecOps engineer explaining a failed CI/CD pipeline run to a student team. "
    "The pipeline is GitHub -> Jenkins -> gitleaks -> pytest -> SonarQube -> checkov -> Docker -> Trivy -> Syft "
    "-> Deployment Risk Score -> push -> Cosign -> Argo Rollouts canary on Kubernetes with Kyverno admission -> "
    "smoke + chaos tests. Security gates failing on purpose is correct behaviour: never suggest disabling a gate. "
    "Answer in Markdown with exactly three sections: '### Root cause' (2-3 sentences), '### Fix' (numbered, "
    "concrete commands or file changes), '### Evidence' (quote the 1-3 log lines that prove it)."
)


def ask_claude(
    log: str,
    stage: str,
    hints: list[Finding],
    api_key: str,
    model: str,
    timeout: float = 60,
) -> str:
    hint_text = "\n".join(f"- {h.title}: {h.cause}" for h in hints)
    body = {
        "model": model,
        "max_tokens": 900,
        "system": SYSTEM,
        "messages": [
            {
                "role": "user",
                "content": f"Failed stage: {stage or 'unknown'}\n\nRule-engine hints:\n{hint_text}\n\n"
                f"Redacted log tail:\n```\n{log[-MAX_LOG_CHARS:]}\n```",
            }
        ],
    }
    req = urllib.request.Request(  # noqa: S310 - fixed https endpoint
        API_URL,
        data=json.dumps(body).encode(),
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        data = json.loads(resp.read())
    return "".join(
        block.get("text", "")
        for block in data.get("content", [])
        if block.get("type") == "text"
    ).strip()


def rules_markdown(findings: list[Finding]) -> str:
    parts = []
    for f in findings:
        fixes = "\n".join(f"{i}. {x}" for i, x in enumerate(f.fix, 1))
        evidence = (
            "\n".join(f"    {e}" for e in f.evidence) or "    (no matching lines)"
        )
        parts.append(
            f"### Root cause: {f.title}\n{f.cause}\n\n### Fix\n{fixes}\n\n### Evidence\n{evidence}\n"
        )
    return "\n".join(parts)


def explain(log: str, stage: str, reports: Path | None, env: dict[str, str]) -> dict:
    clean = redact(log, env)
    findings = analyse(clean, stage, reports)
    key, model = (
        env.get("ANTHROPIC_API_KEY", ""),
        env.get("ANTHROPIC_MODEL") or DEFAULT_MODEL,
    )
    engine, text, error = "rules", rules_markdown(findings), None
    if key and key != "unset":
        try:
            llm = ask_claude(clean, stage, findings, key, model)
            if llm:
                engine, text = f"anthropic:{model}", llm
        except Exception as exc:  # noqa: BLE001 - fall back to rules on any API problem
            error = f"{type(exc).__name__}: {exc}"
    header = f"## Why did this build fail?\n_Stage: {stage or 'unknown'} · engine: {engine}_\n\n"
    if error:
        header += f"_(AI explainer unavailable: {redact(error, env)}; rule-based explanation shown)_\n\n"
    return {
        "engine": engine,
        "stage": stage,
        "summary": findings[0].title,
        "markdown": header + text,
        "findings": [asdict(f) for f in findings],
        "api_error": error,
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="SentinelOps AI failure explainer")
    p.add_argument("--log", type=Path, default=Path("reports/build-log.txt"))
    p.add_argument("--stage", default=os.getenv("CURRENT_STAGE", ""))
    p.add_argument("--reports", type=Path, default=Path("reports"))
    p.add_argument("--out", type=Path, default=Path("reports"))
    p.add_argument("--build-url", default=os.getenv("BUILD_URL", ""))
    args = p.parse_args(argv)
    try:
        log = args.log.read_text(errors="replace")
    except OSError:
        log = ""
    result = explain(log, args.stage, args.reports, dict(os.environ))
    if args.build_url:
        result["markdown"] += f"\n\n[Open the build]({args.build_url})\n"
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "explain.md").write_text(result["markdown"])
    (args.out / "explain.json").write_text(json.dumps(result, indent=2))
    (args.out / "explain-summary.txt").write_text(
        f"{result['summary']} (engine: {result['engine']})"
    )
    print(result["markdown"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
