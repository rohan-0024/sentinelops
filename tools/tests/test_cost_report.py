import json

import pytest

from tools.finops.cost_report import is_schedulable, main, markdown, report

INFRACOST = {
    "currency": "USD",
    "totalMonthlyCost": "230.00",
    "projects": [
        {
            "breakdown": {
                "resources": [
                    {"name": "module.eks.aws_eks_cluster.this", "monthlyCost": "73.00"},
                    {
                        "name": "module.eks.aws_eks_node_group.default",
                        "monthlyCost": "60.74",
                    },
                    {
                        "name": "module.jenkins[0].aws_instance.jenkins",
                        "monthlyCost": "63.14",
                    },
                    {
                        "name": "module.vpc.aws_nat_gateway.this[0]",
                        "monthlyCost": "32.85",
                    },
                    {"name": "aws_kms_key.main", "monthlyCost": "0.27"},
                    {"name": "module.ecr.aws_ecr_repository.this", "monthlyCost": None},
                ]
            }
        }
    ],
}


def test_splits_schedulable_and_always_on():
    r = report(INFRACOST, hours_on_per_month=176)
    assert r["total_monthly"] == 230.0
    assert r["schedulable_monthly"] == pytest.approx(123.88)
    assert r["always_on_monthly"] == pytest.approx(106.12)


def test_autopilot_projection():
    r = report(INFRACOST, hours_on_per_month=176)
    expected_saving = 123.88 * (1 - 176 / 730)
    assert r["savings_monthly"] == pytest.approx(expected_saving, abs=0.01)
    assert r["with_autopilot_monthly"] == pytest.approx(230 - expected_saving, abs=0.01)
    assert report(INFRACOST, hours_on_per_month=730)["savings_monthly"] == 0


def test_schedulable_classification():
    assert is_schedulable("module.eks.aws_eks_node_group.default")
    assert is_schedulable("module.jenkins[0].aws_instance.jenkins")
    assert not is_schedulable("module.eks.aws_eks_cluster.this")
    assert not is_schedulable("module.vpc.aws_nat_gateway.this[0]")


def test_markdown_and_cli(tmp_path):
    src = tmp_path / "infracost.json"
    src.write_text(json.dumps(INFRACOST))
    out = tmp_path / "cost-report.md"
    assert main(["--infracost", str(src), "--out", str(out)]) == 0
    md = out.read_text()
    assert "With FinOps autopilot" in md and "aws_eks_cluster" in md
    assert "aws_ecr_repository" not in md  # zero-cost (usage-based) rows are omitted
    assert json.loads(out.with_suffix(".json").read_text())["total_monthly"] == 230.0
    assert markdown(report({"projects": []}))  # empty breakdown still renders
