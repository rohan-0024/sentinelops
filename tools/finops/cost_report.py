"""Turns an Infracost JSON breakdown into a Markdown cost report with a FinOps-autopilot
projection (Feature 6).

  python3 -m tools.finops.cost_report --infracost reports/infracost.json --out reports/cost-report.md

Schedulable = resources the autopilot stops outside working hours (EKS node group, Jenkins
EC2 and their volumes are billed only while running); always-on = EKS control plane, NAT,
KMS, Secrets Manager, logs. Only `make aws-destroy` removes the always-on part.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HOURS_PER_MONTH = 730
SCHEDULABLE_MARKERS = ("aws_eks_node_group", "aws_instance", "aws_launch_template")


def _money(v) -> float:
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def resources(doc: dict) -> list[dict]:
    out = []
    for project in doc.get("projects") or []:
        for r in (project.get("breakdown") or {}).get("resources") or []:
            out.append(
                {"name": r.get("name", "?"), "monthly": _money(r.get("monthlyCost"))}
            )
    return sorted(out, key=lambda r: -r["monthly"])


def is_schedulable(name: str) -> bool:
    return any(m in name for m in SCHEDULABLE_MARKERS)


def report(doc: dict, hours_on_per_month: float = 176) -> dict:
    res = resources(doc)
    total = _money(doc.get("totalMonthlyCost")) or sum(r["monthly"] for r in res)
    schedulable = sum(r["monthly"] for r in res if is_schedulable(r["name"]))
    on_fraction = min(1.0, hours_on_per_month / HOURS_PER_MONTH)
    with_autopilot = total - schedulable * (1 - on_fraction)
    return {
        "currency": doc.get("currency", "USD"),
        "total_monthly": round(total, 2),
        "schedulable_monthly": round(schedulable, 2),
        "always_on_monthly": round(total - schedulable, 2),
        "hours_on_per_month": hours_on_per_month,
        "with_autopilot_monthly": round(with_autopilot, 2),
        "savings_monthly": round(total - with_autopilot, 2),
        "resources": res,
    }


def markdown(r: dict, top: int = 12) -> str:
    c = r["currency"]
    lines = [
        "## Infrastructure cost estimate (Infracost)",
        "",
        f"| | Monthly ({c}) |",
        "|---|---:|",
        f"| Running 24/7 | {r['total_monthly']:.2f} |",
        f"| of which schedulable (nodes, Jenkins EC2) | {r['schedulable_monthly']:.2f} |",
        f"| of which always-on (EKS control plane, NAT, KMS, logs...) | {r['always_on_monthly']:.2f} |",
        f"| **With FinOps autopilot** ({r['hours_on_per_month']:g} h/month on) | **{r['with_autopilot_monthly']:.2f}** |",
        f"| Saving | {r['savings_monthly']:.2f} |",
        "",
        "| Resource | Monthly |",
        "|---|---:|",
    ]
    lines += [
        f"| `{x['name']}` | {x['monthly']:.2f} |"
        for x in r["resources"][:top]
        if x["monthly"] > 0
    ]
    lines += [
        "",
        "_Usage-based items (NAT data, log ingestion, ECR storage) are excluded unless an Infracost "
        "usage file is supplied._",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--infracost", type=Path, default=Path("reports/infracost.json"))
    p.add_argument("--out", type=Path, default=Path("reports/cost-report.md"))
    p.add_argument(
        "--hours-on",
        type=float,
        default=176,
        help="hours per month the schedulable resources run",
    )
    args = p.parse_args(argv)
    r = report(json.loads(args.infracost.read_text()), args.hours_on)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown(r))
    args.out.with_suffix(".json").write_text(json.dumps(r, indent=2))
    print(markdown(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
