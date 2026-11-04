"""CLI: python3 -m tools.drs --reports reports --config policy/risk.yaml --out reports

Writes drs.json, drs.md and drs.prom. Exit code 0 for auto/canary, 3 for block
(the Jenkinsfile reads drs.json and fails the stage itself; the exit code helps local use).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .score import collect, compute, load_config, markdown, prometheus_text


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="SentinelOps Deployment Risk Score")
    p.add_argument("--reports", default="reports", type=Path)
    p.add_argument("--config", default="policy/risk.yaml", type=Path)
    p.add_argument("--out", default="reports", type=Path)
    args = p.parse_args(argv)

    result = compute(collect(args.reports), load_config(args.config))
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "drs.json").write_text(json.dumps(result.to_dict(), indent=2))
    (args.out / "drs.md").write_text(markdown(result))
    (args.out / "drs.prom").write_text(prometheus_text(result))
    print(markdown(result))
    return 3 if result.decision == "block" else 0


if __name__ == "__main__":
    sys.exit(main())
