import yaml

from tools.monitoring.alertmanager import build_config, render


def receiver(cfg, name):
    return next(r for r in cfg["receivers"] if r["name"] == name)


def test_no_channels_gives_valid_silent_receiver():
    cfg = build_config({"TELEGRAM_BOT_TOKEN": "unset", "SLACK_WEBHOOK_URL": ""})
    chat = receiver(cfg, "chat")
    assert chat == {"name": "chat"}
    assert cfg["route"]["receiver"] == "chat"


def test_telegram_and_slack_are_added_when_configured():
    cfg = build_config(
        {
            "TELEGRAM_BOT_TOKEN": "123:abc",
            "TELEGRAM_CHAT_ID": "-1001",
            "SLACK_WEBHOOK_URL": "https://hooks.example/x",
        }
    )
    chat = receiver(cfg, "chat")
    tg = chat["telegram_configs"][0]
    assert (
        tg["bot_token"] == "123:abc"
        and tg["chat_id"] == -1001
        and tg["send_resolved"] is True
    )
    assert chat["slack_configs"][0]["api_url"] == "https://hooks.example/x"


def test_telegram_needs_both_token_and_chat_id():
    cfg = build_config({"TELEGRAM_BOT_TOKEN": "123:abc", "TELEGRAM_CHAT_ID": "unset"})
    assert "telegram_configs" not in receiver(cfg, "chat")


def test_routing_and_inhibition():
    cfg = build_config({})
    routes = cfg["route"]["routes"]
    assert routes[0]["receiver"] == "null" and "Watchdog" in routes[0]["matchers"][0]
    assert {r["repeat_interval"] for r in routes[1:]} == {"1h", "24h"}
    sources = [r["source_matchers"][0] for r in cfg["inhibit_rules"]]
    assert 'alertname="SentinelOpsErrorBudgetFastBurn"' in sources
    assert {r["name"] for r in cfg["receivers"]} == {"null", "chat"}


def test_render_is_valid_yaml_and_keeps_templates():
    text = render({"TELEGRAM_BOT_TOKEN": "1:x", "TELEGRAM_CHAT_ID": "5"})
    parsed = yaml.safe_load(text)
    assert parsed["receivers"][1]["telegram_configs"][0]["message"].startswith(
        "{{ if eq .Status"
    )
