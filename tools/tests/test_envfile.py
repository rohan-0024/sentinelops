import importlib.util
import string
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "envfile", Path(__file__).resolve().parents[2] / "scripts" / "envfile.py"
)
envfile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(envfile)


def test_strong_password_meets_sonarqube_policy():
    for _ in range(50):
        pw = envfile.strong_password()
        assert len(pw) >= 12
        assert any(c.islower() for c in pw) and any(c.isupper() for c in pw)
        assert any(c.isdigit() for c in pw) and any(c in "!@#%^*-_" for c in pw)
        assert all(c in string.ascii_letters + string.digits + "!@#%^*-_" for c in pw)


def test_init_get_set_roundtrip(tmp_path, monkeypatch):
    example = tmp_path / ".env.example"
    example.write_text(
        "# comment\nJENKINS_ADMIN_PASSWORD=change-me\nSONAR_TOKEN=\nMODE=local\n"
    )
    monkeypatch.setattr(envfile, "ENV", tmp_path / ".env")
    monkeypatch.setattr(envfile, "EXAMPLE", example)

    envfile.init()
    generated = envfile.get("JENKINS_ADMIN_PASSWORD")
    assert generated and not generated.startswith("change-me")
    assert envfile.get("COSIGN_PASSWORD")  # appended when missing
    assert envfile.get("MODE") == "local"

    envfile.init()  # idempotent: existing secrets are kept
    assert envfile.get("JENKINS_ADMIN_PASSWORD") == generated

    envfile.set_("SONAR_TOKEN", "squ_abc")
    assert envfile.get("SONAR_TOKEN") == "squ_abc"
    assert (tmp_path / ".env").read_text().count("SONAR_TOKEN=") == 1
    assert oct((tmp_path / ".env").stat().st_mode)[-3:] == "600"
