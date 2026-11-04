import json
import subprocess
from types import SimpleNamespace

import pytest

from tools.chaos import engine
from tools.chaos.engine import (
    Config,
    Experiment,
    Kube,
    Prober,
    Sample,
    hog_manifest,
    p95,
    prometheus_text,
)


class Clock:
    def __init__(self):
        self.t = 1000.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


class FakeKube:
    """10 pods; deleted pods come back (new names) after `recover_after` seconds."""

    def __init__(self, clock, desired=10, recover_after=8.0, ready_at_start=None):
        self.clock, self.desired, self.recover_after = clock, desired, recover_after
        self.pods = {
            f"app-{i}": 0.0
            for i in range(ready_at_start if ready_at_start is not None else desired)
        }
        self.applied, self.deleted = [], []
        self.counter = 100

    def desired_replicas(self, ns, rollout):
        return self.desired

    def ready_pods(self, ns, selector):
        return sorted(
            n for n, ready_at in self.pods.items() if ready_at <= self.clock.now()
        )

    def delete_pods(self, ns, names):
        for n in names:
            del self.pods[n]
            self.counter += 1
            self.pods[f"app-{self.counter}"] = self.clock.now() + self.recover_after

    def apply(self, manifest):
        self.applied.append(manifest["metadata"]["name"])

    def delete(self, ns, kind, name):
        self.deleted.append(name)


class FakeProber:
    def __init__(self, clock, failures_between=None):
        self.clock, self.failures_between = clock, failures_between
        self.samples, self.started, self.stopped = [], False, False

    def start(self):
        self.started = True

    def stop(self):
        # synthesise one probe per second over the experiment
        t, end = 1000.0, self.clock.now()
        while t <= end:
            bad = (
                self.failures_between
                and self.failures_between[0] <= t < self.failures_between[1]
            )
            self.samples.append(Sample(t, not bad, 0.05 if not bad else 2.0))
            t += 1.0
        self.stopped = True


def run(kube_kwargs=None, prober_kwargs=None, **cfg):
    clock = Clock()
    kube = FakeKube(clock, **(kube_kwargs or {}))
    prober = FakeProber(clock, **(prober_kwargs or {}))
    exp = Experiment(
        Config(stress_seconds=10, **cfg),
        kube,
        prober,
        clock=clock.now,
        sleep=clock.sleep,
        log=lambda m: None,
    )
    return exp.run(), kube, prober


def test_healthy_service_passes_and_measures_recovery():
    report, kube, prober = run()
    assert report.passed and report.reasons == []
    assert report.killed_pods == ["app-0", "app-1", "app-2"]  # 30 % of 10
    assert report.recovery_seconds == pytest.approx(8.0)
    assert report.probe_success_ratio == 1.0
    assert kube.applied == ["chaos-cpu-hog-0", "chaos-cpu-hog-1"] == kube.deleted
    assert prober.started and prober.stopped


def test_slow_recovery_fails_the_gate():
    report, _, _ = run(kube_kwargs={"recover_after": 75.0})
    assert not report.passed and "exceeds limit" in report.reasons[0]


def test_never_recovering_fails_with_timeout():
    report, _, _ = run(kube_kwargs={"recover_after": 10_000.0})
    assert not report.passed and report.recovery_seconds is None
    assert "did not recover" in report.reasons[0]


def test_too_many_failed_probes_fail_the_gate():
    report, _, _ = run(prober_kwargs={"failures_between": (1000.0, 1004.0)})
    assert not report.passed
    assert any("probe success" in r for r in report.reasons)


def test_unsteady_start_is_rejected_without_chaos():
    report, kube, prober = run(kube_kwargs={"ready_at_start": 7})
    assert not report.passed and "steady state" in report.reasons[0]
    assert kube.applied == [] and not prober.started


def test_hog_manifest_is_hardened_and_time_boxed():
    m = hog_manifest(Config(stress_seconds=15), "h")
    c = m["spec"]["containers"][0]
    assert (
        m["metadata"]["namespace"] == "sentinelops-loadgen"
        and m["spec"]["restartPolicy"] == "Never"
    )
    assert "timeout 15" in c["command"][2] and c["resources"]["limits"]["cpu"] == "1"
    assert c["securityContext"]["allowPrivilegeEscalation"] is False


def test_prometheus_text_and_helpers():
    report, _, _ = run()
    text = prometheus_text(report, 1234.9)
    assert (
        "sentinelops_chaos_recovery_seconds 8.0" in text
        and "sentinelops_chaos_passed 1" in text
    )
    assert "sentinelops_chaos_timestamp_seconds 1234" in text
    assert p95([]) == 0 and p95([1, 2, 3, 4, 100]) == 100 and p95([0.1] * 20) == 0.1


def test_kube_wrapper_parses_kubectl_json(monkeypatch):
    pods = {
        "items": [
            {
                "metadata": {"name": "a"},
                "status": {"conditions": [{"type": "Ready", "status": "True"}]},
            },
            {
                "metadata": {"name": "b"},
                "status": {"conditions": [{"type": "Ready", "status": "False"}]},
            },
            {
                "metadata": {"name": "c", "deletionTimestamp": "x"},
                "status": {"conditions": [{"type": "Ready", "status": "True"}]},
            },
        ]
    }
    calls = []

    def fake_run(cmd, input=None, capture_output=True, text=True, check=True):  # noqa: A002
        calls.append(cmd)
        out = json.dumps(pods) if "pods" in cmd else "10"
        return SimpleNamespace(stdout=out)

    monkeypatch.setattr(subprocess, "run", fake_run)
    k = Kube("kind-sentinelops")
    assert k.ready_pods("ns", "app=x") == ["a"]
    assert k.desired_replicas("ns", "r") == 10
    assert calls[0][:3] == ["kubectl", "--context", "kind-sentinelops"]


def test_real_prober_records_failures_for_unreachable_url():
    pr = Prober("http://127.0.0.1:9/api/items", timeout=0.2)
    s = pr.probe_once()
    assert s.ok is False and s.latency >= 0
    assert engine.success_ratio([]) == 1.0
