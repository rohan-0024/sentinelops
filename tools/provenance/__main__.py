"""Writes a SLSA v1.0 provenance *predicate* for the image this build produced; stage 10
attaches it with `cosign attest --type slsaprovenance1`, signed by the pipeline key.

  python3 -m tools.provenance --image REG/REPO@sha256:... --out reports/provenance.json

Everything comes from the Jenkins environment and the workspace: nothing secret is read.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

BUILD_TYPE = (
    "https://github.com/rohan-0024/sentinelops/blob/main/docs/SLSA.md#build-type-v1"
)
FROM_RE = re.compile(r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)", re.I | re.M)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def iso(ts: str | None) -> str | None:
    if not ts:
        return None
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    except ValueError:
        return None


def base_images(dockerfile: Path) -> list[str]:
    try:
        text = dockerfile.read_text()
    except OSError:
        return []
    stages = set(re.findall(r"\bAS\s+(\S+)", text, re.I))
    return [ref for ref in FROM_RE.findall(text) if ref not in stages]


def predicate(image: str, env: dict[str, str], root: Path, now: datetime) -> dict:
    repo = env.get("GIT_URL", "")
    commit = env.get("GIT_COMMIT", "")
    deps: list[dict] = []
    if repo and commit:
        deps.append(
            {
                "uri": f"git+{repo}@{env.get('BRANCH_NAME', '')}",
                "digest": {"gitCommit": commit},
            }
        )
    for ref in base_images(root / "docker" / "Dockerfile"):
        dep: dict = {"uri": f"docker://{ref}"}
        if "@sha256:" in ref:
            dep["digest"] = {"sha256": ref.split("@sha256:", 1)[1]}
        deps.append(dep)
    for rel in ("app/requirements.txt", "versions.env", "policy/risk.yaml"):
        p = root / rel
        if p.is_file():
            deps.append({"uri": rel, "digest": {"sha256": sha256_file(p)}})

    byproducts = []
    for rel in (
        "reports/sbom.cdx.json",
        "reports/trivy-image.json",
        "reports/drs.json",
    ):
        p = root / rel
        if p.is_file():
            byproducts.append({"name": rel, "digest": {"sha256": sha256_file(p)}})

    metadata = {
        "invocationId": env.get("BUILD_URL") or env.get("BUILD_TAG", "local"),
        "finishedOn": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    started = iso(env.get("PIPELINE_START_TS"))
    if started:
        metadata["startedOn"] = started

    return {
        "buildDefinition": {
            "buildType": BUILD_TYPE,
            "externalParameters": {
                "repository": repo,
                "ref": env.get("BRANCH_NAME", ""),
                "mode": env.get("MODE", "local"),
                "image": image,
            },
            "internalParameters": {
                "jenkinsJob": env.get("JOB_NAME", ""),
                "buildNumber": env.get("BUILD_NUMBER", ""),
                "drsDecision": env.get("DRS_DECISION", ""),
            },
            "resolvedDependencies": deps,
        },
        "runDetails": {
            "builder": {
                "id": (env.get("JENKINS_URL") or "local").rstrip("/")
                + "/#sentinelops-pipeline"
            },
            "metadata": metadata,
            "byproducts": byproducts,
        },
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--image", required=True, help="image reference by digest")
    p.add_argument("--out", type=Path, default=Path("reports/provenance.json"))
    p.add_argument("--root", type=Path, default=Path("."))
    args = p.parse_args(argv)
    if "@sha256:" not in args.image:
        print("provenance: --image must be pinned by digest", file=sys.stderr)
        return 2
    doc = predicate(args.image, dict(os.environ), args.root, datetime.now(timezone.utc))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(doc, indent=2))
    print(
        f"provenance predicate: {args.out} ({len(doc['buildDefinition']['resolvedDependencies'])} dependencies)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
