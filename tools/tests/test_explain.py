import io
import json

import pytest

from tools.explain import __main__ as cli
from tools.explain.redact import redact
from tools.explain.rules import analyse


@pytest.mark.parametrize(
    "secret,label",
    [
        ("AKIAABCDEFGHIJKLMNOP", "AWS_ACCESS_KEY"),
        ("sk-ant-api03-abcdefghijklmnop", "ANTHROPIC_KEY"),
        ("ghp_abcdefghijklmnopqrstuvwxyz123456", "GITHUB_TOKEN"),
        ("https://hooks.slack.com/services/T000/B000/XXXX", "SLACK_WEBHOOK"),
        ("squ_0123456789abcdef0123456789abcdef01234567", "SONAR_TOKEN"),
        ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", "JWT"),
    ],
)
def test_redacts_known_token_formats(secret, label):
    out = redact(f"value={secret} done", env={})
    assert secret not in out and f"[REDACTED:{label}]" in out


def test_redacts_private_keys_assignments_url_creds_and_env_values():
    log = (
        "-----BEGIN EC PRIVATE KEY-----\nabc\n-----END EC PRIVATE KEY-----\n"
        "password=hunter2-long\n"
        "git clone https://bob:s3cr3tpw@github.com/x\n"
        "token: my-env-secret-value\n"
    )
    out = redact(log, env={"SONAR_TOKEN": "my-env-secret-value"})
    for leaked in ("abc\n-----END", "hunter2-long", "s3cr3tpw", "my-env-secret-value"):
        assert leaked not in out
    assert "[REDACTED:SONAR_TOKEN]" in out


def test_short_or_unset_env_values_are_not_blindly_replaced():
    assert (
        redact("unset abc", env={"SONAR_TOKEN": "unset", "COSIGN_PASSWORD": "abc"})
        == "unset abc"
    )


@pytest.mark.parametrize(
    "line,rule",
    [
        ("5:22PM WRN 1 leaks found in partial scan", "secret-leak"),
        ("FAILED tests/test_api.py::test_items - AssertionError", "unit-tests"),
        (
            "FAIL Required test coverage of 80% not reached. Total coverage: 61.00%",
            "coverage",
        ),
        ("ERROR: SonarQube quality gate: ERROR", "quality-gate"),
        ("ERROR: Trivy gate failed: 2 fixable CRITICAL vulnerabilities", "trivy-gate"),
        (
            "ERROR: Deployment blocked by the Deployment Risk Score (72 > 60)",
            "drs-block",
        ),
        (
            "DEPLOY BLOCKED BY ADMISSION POLICY (Kyverno) - pods were never created:",
            "admission-denied",
        ),
        ("CANARY FAILED: SLO analysis did not pass.", "canary-failed"),
        ("CHAOS GATE FAILED: recovery 75.0s exceeds limit 60s", "chaos-failed"),
        ("SMOKE FAIL: /ready", "smoke-failed"),
        ("ERROR: no Kubernetes API reachable (KUBECONFIG=unset)", "no-cluster"),
        (
            "Cannot connect to the Docker daemon at unix:///var/run/docker.sock",
            "docker-socket",
        ),
    ],
)
def test_rules_recognise_each_pipeline_failure(line, rule):
    findings = analyse(f"noise\n{line}\nmore noise", stage="x")
    assert findings[0].rule == rule
    assert any(line.strip()[:20] in e for e in findings[0].evidence)


def test_generic_fallback_uses_error_lines():
    f = analyse(
        "step 1\nsomething Exception happened\nERROR: script returned exit code 2",
        stage="5. Docker Build",
    )
    assert f[0].rule == "generic" and "5. Docker Build" in f[0].title
    assert any("exit code 2" in e for e in f[0].evidence)


def test_trivy_and_drs_details_are_attached(tmp_path):
    (tmp_path / "trivy-image.json").write_text(
        json.dumps(
            {
                "Results": [
                    {
                        "Vulnerabilities": [
                            {
                                "VulnerabilityID": "CVE-1",
                                "PkgName": "openssl",
                                "InstalledVersion": "1",
                                "FixedVersion": "2",
                                "Severity": "CRITICAL",
                            }
                        ]
                    }
                ]
            }
        )
    )
    (tmp_path / "drs.json").write_text(
        json.dumps(
            {
                "score": 72,
                "components": [
                    {"name": "iac_failed_checks", "points": 20},
                    {"name": "vuln_high_fixable", "points": 24},
                ],
            }
        )
    )
    log = "Trivy gate failed: 1 fixable CRITICAL\nblocked by the Deployment Risk Score"
    ev = {f.rule: f.evidence for f in analyse(log, reports=tmp_path)}
    assert any("CVE-1: openssl 1 -> 2" in e for e in ev["trivy-gate"])
    assert any("vuln_high_fixable=24" in e for e in ev["drs-block"])


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_uses_claude_when_key_set_and_sends_redacted_log(monkeypatch):
    sent = {}

    def fake_urlopen(req, timeout=0):
        sent["headers"] = dict(req.header_items())
        sent["body"] = json.loads(req.data)
        return FakeResponse(
            json.dumps(
                {"content": [{"type": "text", "text": "### Root cause\nX"}]}
            ).encode()
        )

    monkeypatch.setattr(cli.urllib.request, "urlopen", fake_urlopen)
    env = {
        "ANTHROPIC_API_KEY": "sk-ant-api03-secretkeyvalue",
        "ANTHROPIC_MODEL": "claude-sonnet-5-5",
    }
    out = cli.explain("CANARY FAILED\ntoken=abcdefghijkl", "11. Deploy", None, env)
    assert (
        out["engine"] == "anthropic:claude-sonnet-5-5"
        and "### Root cause\nX" in out["markdown"]
    )
    payload = json.dumps(sent["body"])
    assert "abcdefghijkl" not in payload and "secretkeyvalue" not in payload
    assert sent["body"]["model"] == "claude-sonnet-5-5"
    assert sent["headers"]["X-api-key"] == env["ANTHROPIC_API_KEY"]


def test_falls_back_to_rules_when_api_fails(monkeypatch):
    def boom(req, timeout=0):
        raise OSError("network down")

    monkeypatch.setattr(cli.urllib.request, "urlopen", boom)
    out = cli.explain(
        "CHAOS GATE FAILED: slow",
        "12. Smoke",
        None,
        {"ANTHROPIC_API_KEY": "sk-ant-api03-xxxxxxxxxxxx"},
    )
    assert out["engine"] == "rules" and "network down" in out["api_error"]
    assert "Chaos gate failed" in out["markdown"]


def test_cli_without_key_writes_files(tmp_path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    log = tmp_path / "build-log.txt"
    log.write_text("SMOKE FAIL: /health\npassword=supersecret1")
    assert (
        cli.main(
            [
                "--log",
                str(log),
                "--stage",
                "12. Smoke",
                "--out",
                str(tmp_path),
                "--reports",
                str(tmp_path),
            ]
        )
        == 0
    )
    md = (tmp_path / "explain.md").read_text()
    assert "Post-deploy smoke test failed" in md and "supersecret1" not in md
    assert "engine: rules" in (tmp_path / "explain-summary.txt").read_text()


def test_cli_tolerates_missing_log(tmp_path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert cli.main(["--log", str(tmp_path / "nope.txt"), "--out", str(tmp_path)]) == 0
    assert (
        json.loads((tmp_path / "explain.json").read_text())["findings"][0]["rule"]
        == "generic"
    )
