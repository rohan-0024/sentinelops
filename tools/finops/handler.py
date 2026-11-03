"""FinOps Autopilot (Feature 6).

Runs as an AWS Lambda (EventBridge schedule) *and* as a local CLI
(`python -m tools.finops.handler stop|start|status`). Single file on purpose:
Terraform zips just this file.

stop  : remember the node group's desired size in SSM, scale it to 0, and stop
        running instances tagged Schedule=office-hours.
start : restore the remembered desired size and start those instances.
status: report current state without changing anything.

Manual override: SSM parameter <PARAM_PREFIX>/override = "keep-alive" skips
the *stop* action (start always runs).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
from dataclasses import dataclass, field
from typing import Any

import boto3

log = logging.getLogger("finops")
log.setLevel(logging.INFO)

KEEP_ALIVE = "keep-alive"


@dataclass
class Config:
    cluster_name: str
    nodegroup_name: str
    param_prefix: str = "/sentinelops/finops"
    schedule_tag: str = "office-hours"
    default_desired: int = 2
    dry_run: bool = False
    instance_allow: list[str] = field(default_factory=list)

    @classmethod
    def from_env(cls) -> Config:
        allow = [i for i in os.getenv("INSTANCE_ID_ALLOW", "").split(",") if i.strip()]
        return cls(
            cluster_name=os.environ["CLUSTER_NAME"],
            nodegroup_name=os.environ["NODEGROUP_NAME"],
            param_prefix=os.getenv("PARAM_PREFIX", "/sentinelops/finops").rstrip("/"),
            schedule_tag=os.getenv("SCHEDULE_TAG", "office-hours"),
            default_desired=int(os.getenv("DEFAULT_DESIRED", "2")),
            dry_run=os.getenv("DRY_RUN", "false").lower() == "true",
            instance_allow=allow,
        )


class Autopilot:
    def __init__(self, cfg: Config, session: Any | None = None) -> None:
        session = session or boto3.session.Session()
        self.cfg = cfg
        self.eks = session.client("eks")
        self.ec2 = session.client("ec2")
        self.ssm = session.client("ssm")

    # ---------- SSM helpers ----------
    def _param(self, name: str) -> str | None:
        try:
            return self.ssm.get_parameter(Name=f"{self.cfg.param_prefix}/{name}")[
                "Parameter"
            ]["Value"]
        except self.ssm.exceptions.ParameterNotFound:
            return None

    def _put_param(self, name: str, value: str) -> None:
        self.ssm.put_parameter(
            Name=f"{self.cfg.param_prefix}/{name}",
            Value=value,
            Type="String",
            Overwrite=True,
        )

    def override_active(self) -> bool:
        return (self._param("override") or "").strip().lower() == KEEP_ALIVE

    # ---------- EKS ----------
    def nodegroup_scaling(self) -> dict:
        ng = self.eks.describe_nodegroup(
            clusterName=self.cfg.cluster_name, nodegroupName=self.cfg.nodegroup_name
        )["nodegroup"]
        return ng["scalingConfig"]

    def _scale(self, desired: int, minimum: int, maximum: int) -> None:
        self.eks.update_nodegroup_config(
            clusterName=self.cfg.cluster_name,
            nodegroupName=self.cfg.nodegroup_name,
            scalingConfig={
                "desiredSize": desired,
                "minSize": minimum,
                "maxSize": maximum,
            },
        )

    # ---------- EC2 ----------
    def scheduled_instances(self, states: list[str]) -> list[str]:
        filters = [
            {"Name": "tag:Schedule", "Values": [self.cfg.schedule_tag]},
            {"Name": "instance-state-name", "Values": states},
        ]
        ids: list[str] = []
        for page in self.ec2.get_paginator("describe_instances").paginate(
            Filters=filters
        ):
            for res in page["Reservations"]:
                ids.extend(i["InstanceId"] for i in res["Instances"])
        if self.cfg.instance_allow:
            ids = [i for i in ids if i in self.cfg.instance_allow]
        return sorted(ids)

    # ---------- actions ----------
    def stop(self) -> dict:
        if self.override_active():
            return {"action": "stop", "skipped": True, "reason": "override=keep-alive"}
        scaling = self.nodegroup_scaling()
        instances = self.scheduled_instances(["running", "pending"])
        result = {
            "action": "stop",
            "skipped": False,
            "dry_run": self.cfg.dry_run,
            "nodegroup_previous_desired": scaling["desiredSize"],
            "nodegroup_new_desired": 0,
            "instances_stopped": instances,
        }
        if self.cfg.dry_run:
            return result
        if scaling["desiredSize"] > 0:
            self._put_param("last-desired", str(scaling["desiredSize"]))
        self._scale(0, 0, max(scaling["maxSize"], 1))
        if instances:
            self.ec2.stop_instances(InstanceIds=instances)
        return result

    def start(self) -> dict:
        stored = self._param("last-desired")
        desired = (
            int(stored)
            if stored and stored.isdigit() and int(stored) > 0
            else self.cfg.default_desired
        )
        scaling = self.nodegroup_scaling()
        maximum = max(scaling["maxSize"], desired)
        instances = self.scheduled_instances(["stopped", "stopping"])
        result = {
            "action": "start",
            "dry_run": self.cfg.dry_run,
            "nodegroup_new_desired": desired,
            "instances_started": instances,
        }
        if self.cfg.dry_run:
            return result
        self._scale(desired, min(scaling["minSize"], desired), maximum)
        if instances:
            self.ec2.start_instances(InstanceIds=instances)
        return result

    def status(self) -> dict:
        scaling = self.nodegroup_scaling()
        return {
            "action": "status",
            "override": self._param("override") or "off",
            "nodegroup": scaling,
            "running_instances": self.scheduled_instances(["running", "pending"]),
            "stopped_instances": self.scheduled_instances(["stopped", "stopping"]),
        }

    def run(self, action: str) -> dict:
        actions = {"stop": self.stop, "start": self.start, "status": self.status}
        if action not in actions:
            raise ValueError(
                f"unknown action {action!r}; expected one of {sorted(actions)}"
            )
        result = actions[action]()
        log.info(json.dumps(result))
        return result


def lambda_handler(event: dict, context: Any) -> dict:  # noqa: ARG001 - Lambda signature
    action = (event or {}).get("action", "status")
    return Autopilot(Config.from_env()).run(action)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="SentinelOps FinOps autopilot (local runner)"
    )
    parser.add_argument("action", choices=["stop", "start", "status"])
    parser.add_argument(
        "--cluster", default=os.getenv("CLUSTER_NAME", "sentinelops-eks")
    )
    parser.add_argument(
        "--nodegroup", default=os.getenv("NODEGROUP_NAME", "sentinelops-eks-default")
    )
    parser.add_argument(
        "--prefix", default=os.getenv("PARAM_PREFIX", "/sentinelops/finops")
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    cfg = Config(
        cluster_name=args.cluster,
        nodegroup_name=args.nodegroup,
        param_prefix=args.prefix,
        dry_run=args.dry_run,
    )
    print(json.dumps(Autopilot(cfg).run(args.action), indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
