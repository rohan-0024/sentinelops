#!/usr/bin/env python3
"""Tiny .env helper used by the bootstrap scripts (no third-party deps).

envfile.py init                 create .env from .env.example, replacing change-me values
envfile.py get KEY              print a value
envfile.py set KEY VALUE        set/replace a value
"""

from __future__ import annotations

import re
import secrets
import string
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = ROOT / ".env"
EXAMPLE = ROOT / ".env.example"
LINE = re.compile(r"^([A-Z0-9_]+)=(.*)$")


def strong_password(length: int = 20) -> str:
    """Meets SonarQube's policy: upper, lower, digit and special character."""
    alphabet = string.ascii_letters + string.digits
    while True:
        core = "".join(secrets.choice(alphabet) for _ in range(length - 2))
        pw = core + secrets.choice("!@#%^*-_") + secrets.choice(string.digits)
        if any(c.islower() for c in pw) and any(c.isupper() for c in pw):
            return pw


def read() -> list[str]:
    return ENV.read_text().splitlines() if ENV.exists() else []


def value_of(raw: str) -> str:
    # strip inline comments ("value   # comment") and surrounding quotes
    raw = re.split(r"\s+#", raw, maxsplit=1)[0].strip()
    return raw.strip('"').strip("'")


def get(key: str) -> str:
    for line in read():
        m = LINE.match(line)
        if m and m.group(1) == key:
            return value_of(m.group(2))
    return ""


def set_(key: str, value: str) -> None:
    lines = read()
    for i, line in enumerate(lines):
        m = LINE.match(line)
        if m and m.group(1) == key:
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    ENV.write_text("\n".join(lines) + "\n")
    ENV.chmod(0o600)


def init() -> None:
    if not ENV.exists():
        ENV.write_text(EXAMPLE.read_text())
        print("created .env from .env.example")
    generated = []
    for key in (
        "JENKINS_ADMIN_PASSWORD",
        "SONAR_ADMIN_PASSWORD",
        "SONAR_DB_PASSWORD",
        "COSIGN_PASSWORD",
        "GRAFANA_ADMIN_PASSWORD",
    ):
        current = get(key)
        if not current or current.startswith("change-me"):
            set_(key, strong_password())
            generated.append(key)
    if generated:
        print("generated strong values for: " + ", ".join(generated))
    ENV.chmod(0o600)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "init":
        init()
    elif cmd == "get" and len(argv) == 2:
        print(get(argv[1]))
    elif cmd == "set" and len(argv) == 3:
        set_(argv[1], argv[2])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
