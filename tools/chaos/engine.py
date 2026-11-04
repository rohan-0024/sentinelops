"""Chaos experiments driven through kubectl (works the same on kind and EKS).

Experiment:
  1. steady state: ready pods == desired replicas
  2. pod-kill:   delete ~30 % of app pods, time until all replicas are Ready again
  3. cpu-stress: run CPU-hog pods next to the app for N seconds
  throughout:    probe the API and record success + latency
Pass when recovery <= limit and probe success ratio >= minimum.
"""

from __future__ import annotations

import json
import math
import subprocess
import threading
import time
import urllib.request
from collections.abc import Callable
from dataclasses import asdict, dataclass, field


# ----------------------------------------------------------------- cluster access
class Kube:
    """Thin kubectl wrapper (kubectl is in the Jenkins image and on the laptop PATH)."""

    def __init__(self, context: str | None = None) -> None:
        self.base = ["kubectl"] + (["--context", context] if context else [])

    def _run(self, *args: str, stdin: str | None = None) -> str:
        return subprocess.run(  # noqa: S603 - fixed binary, arguments built by this module
            [*self.base, *args], input=stdin, capture_output=True, text=True, check=True
        ).stdout

    def desired_replicas(self, ns: str, rollout: str) -> int:
        return int(
            self._run(
                "-n", ns, "get", "rollout", rollout, "-o", "jsonpath={.spec.replicas}"
            )
        )

    def ready_pods(self, ns: str, selector: str) -> list[str]:
        pods = json.loads(
            self._run("-n", ns, "get", "pods", "-l", selector, "-o", "json")
        )["items"]
        ready = []
        for p in pods:
            if p["metadata"].get("deletionTimestamp"):
                continue
            conds = {
                c["type"]: c["status"]
                for c in p.get("status", {}).get("conditions", [])
            }
            if conds.get("Ready") == "True":
                ready.append(p["metadata"]["name"])
        return sorted(ready)

    def delete_pods(self, ns: str, names: list[str]) -> None:
        self._run("-n", ns, "delete", "pod", *names, "--wait=false")

    def apply(self, manifest: dict) -> None:
        self._run("apply", "-f", "-", stdin=json.dumps(manifest))

    def delete(self, ns: str, kind: str, name: str) -> None:
        self._run("-n", ns, "delete", kind, name, "--ignore-not-found", "--wait=false")


# ----------------------------------------------------------------- probing
@dataclass
class Sample:
    t: float
    ok: bool
    latency: float


class Prober:
    """Background HTTP prober recording success and latency of each request."""

    def __init__(
        self,
        url: str,
        interval: float = 0.2,
        timeout: float = 2.0,
        clock: Callable[[], float] = time.time,
    ):
        self.url, self.interval, self.timeout, self.clock = (
            url,
            interval,
            timeout,
            clock,
        )
        self.samples: list[Sample] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def probe_once(self) -> Sample:
        start = self.clock()
        try:
            with urllib.request.urlopen(self.url, timeout=self.timeout) as r:  # noqa: S310 - http(s) URL from config
                ok = 200 <= r.status < 300
        except Exception:  # noqa: BLE001 - any failure is a failed probe
            ok = False
        return Sample(start, ok, self.clock() - start)

    def _loop(self) -> None:
        while not self._stop.is_set():
            self.samples.append(self.probe_once())
            self._stop.wait(self.interval)

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)


def success_ratio(samples: list[Sample]) -> float:
    return sum(s.ok for s in samples) / len(samples) if samples else 1.0


def p95(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(0.95 * len(ordered)) - 1)]


# ----------------------------------------------------------------- experiment
@dataclass
class Config:
    namespace: str = "sentinelops"
    rollout: str = "sentinelops-app"
    selector: str = "app.kubernetes.io/name=sentinelops-app"
    kill_fraction: float = 0.3
    recovery_limit: float = 60.0
    min_success_ratio: float = 0.95
    stress_namespace: str = "sentinelops-loadgen"
    stress_pods: int = 2
    stress_seconds: int = 20
    stress_image: str = "curlimages/curl:8.11.1"
    poll_interval: float = 1.0


@dataclass
class Report:
    passed: bool
    recovery_seconds: float | None
    killed_pods: list[str]
    desired_replicas: int
    probe_success_ratio: float
    probes: int
    kill_window_success_ratio: float
    stress_p95_latency_seconds: float
    reasons: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def hog_manifest(cfg: Config, name: str) -> dict:
    loop = f"timeout {cfg.stress_seconds} sh -c 'while :; do :; done' || true"
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": name,
            "namespace": cfg.stress_namespace,
            "labels": {"app": "chaos-cpu-hog"},
        },
        "spec": {
            "restartPolicy": "Never",
            "automountServiceAccountToken": False,
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 10001,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
            "containers": [
                {
                    "name": "hog",
                    "image": cfg.stress_image,
                    "command": ["/bin/sh", "-c", loop],
                    "resources": {
                        "requests": {"cpu": "500m", "memory": "8Mi"},
                        "limits": {"cpu": "1", "memory": "16Mi"},
                    },
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "readOnlyRootFilesystem": True,
                        "capabilities": {"drop": ["ALL"]},
                    },
                }
            ],
        },
    }


class Experiment:
    def __init__(
        self,
        cfg: Config,
        kube,
        prober,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        log: Callable[[str], None] = print,
    ):
        self.cfg, self.kube, self.prober, self.clock, self.sleep, self.log = (
            cfg,
            kube,
            prober,
            clock,
            sleep,
            log,
        )

    def _wait_recovered(
        self, desired: int, victims: list[str], start: float
    ) -> float | None:
        deadline = start + self.cfg.recovery_limit * 2
        while self.clock() <= deadline:
            ready = [
                p
                for p in self.kube.ready_pods(self.cfg.namespace, self.cfg.selector)
                if p not in victims
            ]
            if len(ready) >= desired:
                return self.clock() - start
            self.sleep(self.cfg.poll_interval)
        return None

    def run(self) -> Report:
        cfg = self.cfg
        desired = self.kube.desired_replicas(cfg.namespace, cfg.rollout)
        ready = self.kube.ready_pods(cfg.namespace, cfg.selector)
        reasons: list[str] = []
        if len(ready) < desired:
            reasons.append(
                f"not in steady state before chaos: {len(ready)}/{desired} ready"
            )
            return Report(False, None, [], desired, 0.0, 0, 0.0, 0.0, reasons)

        self.prober.start()
        try:
            k = max(1, round(desired * cfg.kill_fraction))
            victims = ready[:k]
            self.log(f"pod-kill: deleting {k}/{desired} pods: {', '.join(victims)}")
            t_kill = self.clock()
            self.kube.delete_pods(cfg.namespace, victims)
            recovery = self._wait_recovered(desired, victims, t_kill)
            t_recovered = self.clock()
            self.log(
                f"pod-kill: recovered in {recovery:.1f}s"
                if recovery is not None
                else "pod-kill: NOT recovered"
            )

            hogs = [f"chaos-cpu-hog-{i}" for i in range(cfg.stress_pods)]
            self.log(
                f"cpu-stress: {cfg.stress_pods} CPU hog pods for {cfg.stress_seconds}s"
            )
            t_stress = self.clock()
            for h in hogs:
                self.kube.apply(hog_manifest(cfg, h))
            self.sleep(cfg.stress_seconds)
            t_stress_end = self.clock()
            for h in hogs:
                self.kube.delete(cfg.stress_namespace, "pod", h)
        finally:
            self.prober.stop()

        samples = self.prober.samples
        kill_window = [s for s in samples if t_kill <= s.t <= t_recovered]
        stress_window = [
            s.latency for s in samples if t_stress <= s.t <= t_stress_end and s.ok
        ]
        ratio = success_ratio(samples)
        if recovery is None:
            reasons.append(f"pods did not recover within {cfg.recovery_limit * 2:.0f}s")
        elif recovery > cfg.recovery_limit:
            reasons.append(
                f"recovery {recovery:.1f}s exceeds limit {cfg.recovery_limit:.0f}s"
            )
        if ratio < cfg.min_success_ratio:
            reasons.append(
                f"probe success {ratio:.1%} below {cfg.min_success_ratio:.0%}"
            )
        return Report(
            passed=not reasons,
            recovery_seconds=None if recovery is None else round(recovery, 2),
            killed_pods=victims,
            desired_replicas=desired,
            probe_success_ratio=round(ratio, 4),
            probes=len(samples),
            kill_window_success_ratio=round(success_ratio(kill_window), 4),
            stress_p95_latency_seconds=round(p95(stress_window), 4),
            reasons=reasons,
        )


def prometheus_text(report: Report, now: float) -> str:
    rec = report.recovery_seconds if report.recovery_seconds is not None else -1
    return (
        "# TYPE sentinelops_chaos_recovery_seconds gauge\n"
        f"sentinelops_chaos_recovery_seconds {rec}\n"
        "# TYPE sentinelops_chaos_success_ratio gauge\n"
        f"sentinelops_chaos_success_ratio {report.probe_success_ratio}\n"
        "# TYPE sentinelops_chaos_passed gauge\n"
        f"sentinelops_chaos_passed {1 if report.passed else 0}\n"
        "# TYPE sentinelops_chaos_stress_p95_latency_seconds gauge\n"
        f"sentinelops_chaos_stress_p95_latency_seconds {report.stress_p95_latency_seconds}\n"
        "# TYPE sentinelops_chaos_timestamp_seconds gauge\n"
        f"sentinelops_chaos_timestamp_seconds {int(now)}\n"
    )
