"""CLI: python3 -m tools.chaos --url http://host:30080 [--namespace sentinelops] [--app sentinelops-app]

Writes reports/chaos.json and reports/chaos.prom, pushes the metrics to the Pushgateway
when PUSHGATEWAY_URL is set, and exits 1 if the chaos gate fails.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

from .engine import Config, Experiment, Kube, Prober, prometheus_text


def push(text: str, url: str, branch: str) -> None:
    instance = "".join(c if c.isalnum() or c in "._-" else "_" for c in branch)
    req = urllib.request.Request(  # noqa: S310 - http(s) URL from config
        f"{url.rstrip('/')}/metrics/job/sentinelops_pipeline/instance/{instance}",
        data=text.encode(),
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10).close()  # noqa: S310
        print(f"chaos metrics pushed to {url}")
    except Exception as exc:  # noqa: BLE001 - metrics are best effort
        print(f"chaos metrics push failed ({exc}); continuing")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="SentinelOps chaos gate")
    p.add_argument("--url", required=True, help="app base URL")
    p.add_argument("--namespace", default="sentinelops")
    p.add_argument("--app", default="sentinelops-app")
    p.add_argument("--context", default=os.getenv("KUBE_CONTEXT"))
    p.add_argument(
        "--recovery-limit",
        type=float,
        default=float(os.getenv("CHAOS_RECOVERY_LIMIT", "60")),
    )
    p.add_argument(
        "--min-success",
        type=float,
        default=float(os.getenv("CHAOS_MIN_SUCCESS", "0.95")),
    )
    p.add_argument(
        "--stress-seconds",
        type=int,
        default=int(os.getenv("CHAOS_STRESS_SECONDS", "20")),
    )
    p.add_argument(
        "--stress-image", default=os.getenv("LOADGEN_IMAGE", "curlimages/curl:8.11.1")
    )
    p.add_argument("--out", default="reports", type=Path)
    args = p.parse_args(argv)

    cfg = Config(
        namespace=args.namespace,
        rollout=args.app,
        selector=f"app.kubernetes.io/name={args.app}",
        recovery_limit=args.recovery_limit,
        min_success_ratio=args.min_success,
        stress_seconds=args.stress_seconds,
        stress_image=args.stress_image,
    )
    report = Experiment(
        cfg, Kube(args.context), Prober(f"{args.url.rstrip('/')}/api/items")
    ).run()

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "chaos.json").write_text(json.dumps(report.to_dict(), indent=2))
    text = prometheus_text(report, time.time())
    (args.out / "chaos.prom").write_text(text)
    if os.getenv("PUSHGATEWAY_URL"):
        push(text, os.environ["PUSHGATEWAY_URL"], os.getenv("BRANCH_NAME", "main"))

    print(json.dumps(report.to_dict(), indent=2))
    print(
        "CHAOS GATE "
        + ("PASSED" if report.passed else "FAILED: " + "; ".join(report.reasons))
    )
    return 0 if report.passed else 1


if __name__ == "__main__":
    sys.exit(main())
