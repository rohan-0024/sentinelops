#!/usr/bin/env bash
# Monitoring tests that need the real Prometheus/Alertmanager binaries (pinned images):
#   promtool check rules + promtool test rules (alert/recording unit tests)
#   amtool check-config on the rendered Alertmanager config
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"
PY="${ROOT}/.venv/bin/python"
[[ -x "${PY}" ]] || PY=python3
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "== promtool check rules"
docker run --rm -v "${ROOT}/monitoring:/m:ro" --entrypoint promtool "${PROMETHEUS_IMAGE}" \
  check rules /m/prometheus/sentinelops-slo.rules.yaml /m/prometheus/sentinelops-delivery.rules.yaml

echo "== promtool test rules"
docker run --rm -v "${ROOT}/monitoring:/m:ro" -w /m/tests --entrypoint promtool "${PROMETHEUS_IMAGE}" \
  test rules slo.test.yaml delivery.test.yaml

echo "== amtool check-config (with dummy Telegram + Slack so every integration is validated)"
(cd "${ROOT}" && TELEGRAM_BOT_TOKEN=1:x TELEGRAM_CHAT_ID=1 SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T/B/X \
  "${PY}" -m tools.monitoring.alertmanager) > "${TMP}/alertmanager.yaml"
# The alertmanager image runs as "nobody": make the (dummy-token) config readable to it.
chmod 755 "${TMP}"
chmod 644 "${TMP}/alertmanager.yaml"
docker run --rm -v "${TMP}:/c:ro" --entrypoint amtool "${ALERTMANAGER_IMAGE}" check-config /c/alertmanager.yaml
echo "monitoring-test: OK"
