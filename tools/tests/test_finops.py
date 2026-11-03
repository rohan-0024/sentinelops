"""FinOps autopilot tests against moto-mocked EC2 and SSM; EKS is stubbed
because moto's node-group scaling support is partial."""

import os

import boto3
import pytest
from moto import mock_aws

from tools.finops.handler import Autopilot, Config, lambda_handler

REGION = "us-east-1"
PREFIX = "/sentinelops/finops"


class FakeEks:
    def __init__(self, desired=2, minimum=0, maximum=3):
        self.scaling = {"desiredSize": desired, "minSize": minimum, "maxSize": maximum}
        self.updates = []

    def describe_nodegroup(self, clusterName, nodegroupName):  # noqa: N803
        return {"nodegroup": {"scalingConfig": dict(self.scaling)}}

    def update_nodegroup_config(self, clusterName, nodegroupName, scalingConfig):  # noqa: N803
        self.updates.append(scalingConfig)
        self.scaling = dict(scalingConfig)


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")


def make_pilot(fake_eks, **cfg):
    pilot = Autopilot(
        Config(cluster_name="c", nodegroup_name="ng", param_prefix=PREFIX, **cfg)
    )
    pilot.eks = fake_eks
    return pilot


def launch(ec2, tags):
    image = ec2.describe_images(Owners=["amazon"])["Images"][0]["ImageId"]
    r = ec2.run_instances(
        ImageId=image,
        MinCount=1,
        MaxCount=1,
        InstanceType="t3.micro",
        TagSpecifications=[
            {
                "ResourceType": "instance",
                "Tags": [{"Key": k, "Value": v} for k, v in tags.items()],
            }
        ],
    )
    return r["Instances"][0]["InstanceId"]


def state(ec2, iid):
    return ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0][
        "State"
    ]["Name"]


@mock_aws
def test_stop_scales_to_zero_stops_only_tagged_instances_and_remembers_size():
    ec2 = boto3.client("ec2", region_name=REGION)
    ssm = boto3.client("ssm", region_name=REGION)
    tagged = launch(ec2, {"Schedule": "office-hours"})
    untagged = launch(ec2, {"Schedule": "always-on"})
    eks = FakeEks(desired=2)

    result = make_pilot(eks).run("stop")

    assert result["skipped"] is False
    assert result["instances_stopped"] == [tagged]
    assert eks.scaling == {"desiredSize": 0, "minSize": 0, "maxSize": 3}
    assert state(ec2, tagged) in ("stopping", "stopped")
    assert state(ec2, untagged) == "running"
    assert ssm.get_parameter(Name=f"{PREFIX}/last-desired")["Parameter"]["Value"] == "2"


@mock_aws
def test_override_keep_alive_skips_stop():
    ec2 = boto3.client("ec2", region_name=REGION)
    boto3.client("ssm", region_name=REGION).put_parameter(
        Name=f"{PREFIX}/override", Value="keep-alive", Type="String"
    )
    tagged = launch(ec2, {"Schedule": "office-hours"})
    eks = FakeEks(desired=2)

    result = make_pilot(eks).run("stop")

    assert result == {
        "action": "stop",
        "skipped": True,
        "reason": "override=keep-alive",
    }
    assert eks.updates == []
    assert state(ec2, tagged) == "running"


@mock_aws
def test_start_restores_remembered_size_and_starts_instances():
    ec2 = boto3.client("ec2", region_name=REGION)
    tagged = launch(ec2, {"Schedule": "office-hours"})
    eks = FakeEks(desired=3, maximum=3)
    pilot = make_pilot(eks)
    pilot.run("stop")
    ec2.stop_instances(InstanceIds=[tagged])  # ensure fully stopped in moto

    result = pilot.run("start")

    assert result["nodegroup_new_desired"] == 3
    assert result["instances_started"] == [tagged]
    assert eks.scaling["desiredSize"] == 3
    assert state(ec2, tagged) in ("pending", "running")


@mock_aws
def test_start_without_memory_uses_default():
    eks = FakeEks(desired=0, maximum=1)
    result = make_pilot(eks, default_desired=2).run("start")
    assert result["nodegroup_new_desired"] == 2
    assert eks.scaling == {"desiredSize": 2, "minSize": 0, "maxSize": 2}


@mock_aws
def test_dry_run_changes_nothing():
    ec2 = boto3.client("ec2", region_name=REGION)
    tagged = launch(ec2, {"Schedule": "office-hours"})
    eks = FakeEks(desired=2)
    result = make_pilot(eks, dry_run=True).run("stop")
    assert result["dry_run"] is True and result["instances_stopped"] == [tagged]
    assert eks.updates == []
    assert state(ec2, tagged) == "running"


@mock_aws
def test_allow_list_limits_instances():
    ec2 = boto3.client("ec2", region_name=REGION)
    a = launch(ec2, {"Schedule": "office-hours"})
    launch(ec2, {"Schedule": "office-hours"})
    result = make_pilot(FakeEks(), instance_allow=[a]).run("stop")
    assert result["instances_stopped"] == [a]


@mock_aws
def test_status_and_unknown_action():
    pilot = make_pilot(FakeEks(desired=1))
    s = pilot.run("status")
    assert s["override"] == "off" and s["nodegroup"]["desiredSize"] == 1
    with pytest.raises(ValueError):
        pilot.run("explode")


@mock_aws
def test_lambda_handler_reads_env(monkeypatch):
    monkeypatch.setenv("CLUSTER_NAME", "c")
    monkeypatch.setenv("NODEGROUP_NAME", "ng")
    monkeypatch.setenv("DRY_RUN", "true")
    fake = FakeEks(desired=2)
    original_init = Autopilot.__init__

    def patched_init(self, cfg, session=None):
        original_init(self, cfg, session)
        self.eks = fake

    monkeypatch.setattr(Autopilot, "__init__", patched_init)
    result = lambda_handler({"action": "stop"}, None)
    assert result["dry_run"] is True and fake.updates == []
    assert os.environ["CLUSTER_NAME"] == "c"
