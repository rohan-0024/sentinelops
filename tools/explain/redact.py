"""Removes secrets from build logs before they leave the CI host (chat, LLM, artifacts)."""

from __future__ import annotations

import os
import re

PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "PRIVATE_KEY",
        re.compile(
            r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
            re.S,
        ),
    ),
    ("AWS_ACCESS_KEY", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("ANTHROPIC_KEY", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{10,}")),
    ("GITHUB_TOKEN", re.compile(r"\b(?:ghp|gho|ghs|ghu|github_pat)_[A-Za-z0-9_]{20,}")),
    ("SLACK_TOKEN", re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}")),
    (
        "SLACK_WEBHOOK",
        re.compile(r"https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]+"),
    ),
    ("TELEGRAM_TOKEN", re.compile(r"\b\d{6,12}:[A-Za-z0-9_\-]{30,}\b")),
    ("SONAR_TOKEN", re.compile(r"\bsq[upa]_[a-f0-9]{30,}\b")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+")),
    ("URL_CREDENTIALS", re.compile(r"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)")),
    ("BEARER", re.compile(r"(?i)(?<=bearer )[A-Za-z0-9._\-]{16,}")),
]

# key=value / key: value assignments: group 1 (the key part) is kept, the value is replaced.
ASSIGNMENT = re.compile(
    r"(?i)(\b(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)[\"']?\s*[:=]\s*[\"']?)(?!\[REDACTED)[^\s\"',]{6,}"
)

# Values of these environment variables are replaced literally wherever they appear.
SECRET_ENV = (
    "ANTHROPIC_API_KEY",
    "SONAR_TOKEN",
    "SONAR_AUTH_TOKEN",
    "COSIGN_PASSWORD",
    "COSIGN_KEY_B64",
    "TELEGRAM_BOT_TOKEN",
    "SLACK_WEBHOOK_URL",
    "JENKINS_ADMIN_PASSWORD",
    "INFRACOST_API_KEY",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "GRAFANA_ADMIN_PASSWORD",
)


def redact(text: str, env: dict[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    for name in SECRET_ENV:
        value = env.get(name, "")
        if value and value != "unset" and len(value) >= 6:
            text = text.replace(value, f"[REDACTED:{name}]")
    for label, pattern in PATTERNS:
        text = pattern.sub(f"[REDACTED:{label}]", text)
    return ASSIGNMENT.sub(lambda m: m.group(1) + "[REDACTED:VALUE]", text)
