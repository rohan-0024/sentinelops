"""Renders the Alertmanager configuration from .env values (tokens never touch git).

Routing:
  critical -> chat receiver, repeat every 1h
  warning  -> chat receiver, repeat every 4h
  info     -> chat receiver, repeat every 24h
  Watchdog / InfoInhibitor (kube-prometheus-stack internals) -> null
The "chat" receiver gets a Telegram and/or Slack integration when configured; with
neither it is a valid receiver with no integrations (alerts stay visible in the
Alertmanager UI and Grafana).

  python3 -m tools.monitoring.alertmanager > alertmanager.yaml
"""

from __future__ import annotations

import os
import sys
from typing import Any

import yaml

UNSET = {"", "unset", None}


def build_config(env: dict[str, str]) -> dict[str, Any]:
    chat: dict[str, Any] = {"name": "chat"}
    token, chat_id = env.get("TELEGRAM_BOT_TOKEN"), env.get("TELEGRAM_CHAT_ID")
    if token not in UNSET and chat_id not in UNSET:
        chat["telegram_configs"] = [
            {
                "bot_token": token,
                "chat_id": int(chat_id),
                "parse_mode": "HTML",
                "send_resolved": True,
                "message": (
                    '{{ if eq .Status "firing" }}🔥{{ else }}✅{{ end }} '
                    "<b>{{ .CommonLabels.alertname }}</b> ({{ .CommonLabels.severity }})\n"
                    "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
                ),
            }
        ]
    slack = env.get("SLACK_WEBHOOK_URL")
    if slack not in UNSET:
        chat["slack_configs"] = [
            {
                "api_url": slack,
                "send_resolved": True,
                "title": "{{ .Status | toUpper }}: {{ .CommonLabels.alertname }} ({{ .CommonLabels.severity }})",
                "text": "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ .Annotations.description }}\n{{ end }}",
            }
        ]

    return {
        "global": {"resolve_timeout": "5m"},
        "route": {
            "receiver": "chat",
            "group_by": ["alertname", "severity"],
            "group_wait": "30s",
            "group_interval": "5m",
            "repeat_interval": "4h",
            "routes": [
                {
                    "receiver": "null",
                    "matchers": ['alertname=~"Watchdog|InfoInhibitor"'],
                },
                {
                    "receiver": "chat",
                    "matchers": ['severity="critical"'],
                    "repeat_interval": "1h",
                },
                {
                    "receiver": "chat",
                    "matchers": ['severity="info"'],
                    "repeat_interval": "24h",
                },
            ],
        },
        "inhibit_rules": [
            {
                # A fast burn already pages; don't also send the slow-burn warning.
                "source_matchers": ['alertname="SentinelOpsErrorBudgetFastBurn"'],
                "target_matchers": ['alertname="SentinelOpsErrorBudgetSlowBurn"'],
            },
            {
                # When the app is down, SLO alerts are noise.
                "source_matchers": ['alertname="SentinelOpsAppDown"'],
                "target_matchers": ['slo=~"availability|latency"'],
            },
        ],
        "receivers": [{"name": "null"}, chat],
    }


def render(env: dict[str, str]) -> str:
    return yaml.safe_dump(build_config(env), sort_keys=False, allow_unicode=True)


def main() -> int:
    sys.stdout.write(render(dict(os.environ)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
