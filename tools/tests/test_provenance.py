import json
from datetime import datetime, timezone

from tools.provenance.__main__ import base_images, main, predicate

NOW = datetime(2026, 11, 4, 12, 0, tzinfo=timezone.utc)
IMAGE = "kind-registry:5000/sentinelops-app@sha256:" + "a" * 64


def workspace(tmp_path):
    (tmp_path / "docker").mkdir()
    (tmp_path / "docker" / "Dockerfile").write_text(
        "FROM python:3.11.11-slim-bookworm AS build\nRUN true\n"
        "FROM gcr.io/distroless/python3-debian12@sha256:" + "b" * 64 + " AS runtime\n"
        "COPY --from=build /x /x\n"
    )
    (tmp_path / "app").mkdir()
    (tmp_path / "app" / "requirements.txt").write_text("fastapi==0.115.6\n")
    (tmp_path / "reports").mkdir()
    (tmp_path / "reports" / "sbom.cdx.json").write_text("{}")
    return tmp_path


ENV = {
    "GIT_URL": "https://github.com/rohan-0024/sentinelops.git",
    "GIT_COMMIT": "fcaf4cb0994971632c1f1bfc3404d80ee4362b5e",
    "BRANCH_NAME": "main",
    "BUILD_URL": "http://localhost:8080/job/sentinelops/job/main/28/",
    "JENKINS_URL": "http://localhost:8080/",
    "PIPELINE_START_TS": "1793793180",
    "DRS_DECISION": "canary",
}


def test_base_images_skip_stage_aliases(tmp_path):
    ws = workspace(tmp_path)
    refs = base_images(ws / "docker" / "Dockerfile")
    assert refs[0] == "python:3.11.11-slim-bookworm" and len(refs) == 2


def test_predicate_follows_slsa_v1_shape(tmp_path):
    p = predicate(IMAGE, ENV, workspace(tmp_path), NOW)
    bd, rd = p["buildDefinition"], p["runDetails"]
    assert set(bd) == {
        "buildType",
        "externalParameters",
        "internalParameters",
        "resolvedDependencies",
    }
    assert bd["resolvedDependencies"][0]["digest"] == {"gitCommit": ENV["GIT_COMMIT"]}
    pinned = [
        d for d in bd["resolvedDependencies"] if d["uri"].startswith("docker://gcr.io")
    ]
    assert pinned[0]["digest"] == {"sha256": "b" * 64}
    assert rd["builder"]["id"] == "http://localhost:8080/#sentinelops-pipeline"
    assert rd["metadata"]["invocationId"] == ENV["BUILD_URL"]
    assert (
        rd["metadata"]["startedOn"].endswith("Z")
        and rd["metadata"]["finishedOn"] == "2026-11-04T12:00:00Z"
    )
    assert rd["byproducts"][0]["name"] == "reports/sbom.cdx.json"


def test_no_secrets_from_environment_leak_into_predicate(tmp_path):
    env = dict(ENV, COSIGN_PASSWORD="hunter2-very-secret", SONAR_TOKEN="tok-123456")
    text = json.dumps(predicate(IMAGE, env, workspace(tmp_path), NOW))
    assert "hunter2" not in text and "tok-123456" not in text


def test_cli_rejects_tag_reference(tmp_path):
    assert (
        main(["--image", "registry/app:latest", "--out", str(tmp_path / "p.json")]) == 2
    )


def test_cli_writes_file(tmp_path, monkeypatch):
    ws = workspace(tmp_path)
    for k, v in ENV.items():
        monkeypatch.setenv(k, v)
    out = tmp_path / "prov.json"
    assert main(["--image", IMAGE, "--out", str(out), "--root", str(ws)]) == 0
    assert (
        json.loads(out.read_text())["buildDefinition"]["externalParameters"]["image"]
        == IMAGE
    )
