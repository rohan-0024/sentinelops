# Dedicated least-privilege roles for a STANDARD AWS account (lab_mode = false).
# In AWS Academy (lab_mode = true) this module is not instantiated; the root
# module passes the pre-existing LabRole instead.

data "aws_partition" "current" {}

locals {
  arn = "arn:${data.aws_partition.current.partition}"
}

data "aws_iam_policy_document" "assume" {
  for_each = {
    eks_cluster = "eks.amazonaws.com"
    eks_node    = "ec2.amazonaws.com"
    jenkins     = "ec2.amazonaws.com"
    finops      = "lambda.amazonaws.com"
  }
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = [each.value]
    }
  }
}

# ---- EKS control plane ----
resource "aws_iam_role" "eks_cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.assume["eks_cluster"].json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "${local.arn}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---- EKS worker nodes ----
resource "aws_iam_role" "eks_node" {
  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.assume["eks_node"].json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = "${local.arn}:iam::aws:policy/${each.value}"
}

# ---- Jenkins EC2: push to one ECR repo, describe one EKS cluster ----
resource "aws_iam_role" "jenkins" {
  name               = "${var.name}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.assume["jenkins"].json
}

data "aws_iam_policy_document" "jenkins" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken does not support resource-level permissions
  }
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload",
      "ecr:PutImage", "ecr:UploadLayerPart", "ecr:DescribeImageScanFindings",
    ]
    resources = [var.ecr_repository_arn]
  }
  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = ["${local.arn}:eks:*:*:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "ci-deploy"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "${local.arn}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name}-jenkins"
  role = aws_iam_role.jenkins.name
}

# ---- FinOps Lambda: scale one node group, stop/start tagged instances ----
resource "aws_iam_role" "finops" {
  name               = "${var.name}-finops-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume["finops"].json
}

data "aws_iam_policy_document" "finops" {
  statement {
    sid       = "ScaleNodegroup"
    actions   = ["eks:DescribeNodegroup", "eks:UpdateNodegroupConfig"]
    resources = ["${local.arn}:eks:*:*:nodegroup/${var.cluster_name}/*/*"]
  }
  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"] # Describe* does not support resource-level permissions
  }
  statement {
    sid       = "StopStartTaggedInstances"
    actions   = ["ec2:StopInstances", "ec2:StartInstances"]
    resources = ["${local.arn}:ec2:*:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Schedule"
      values   = ["office-hours"]
    }
  }
  statement {
    sid       = "OverrideAndState"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["${local.arn}:ssm:*:*:parameter/${var.name}/finops/*"]
  }
  statement {
    sid       = "DeadLetterQueue"
    actions   = ["sqs:SendMessage"]
    resources = ["${local.arn}:sqs:*:*:${var.name}-finops-dlq"]
  }
  statement {
    sid       = "KmsForEnvAndDlq"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray write actions do not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "finops" {
  name   = "finops-autopilot"
  role   = aws_iam_role.finops.id
  policy = data.aws_iam_policy_document.finops.json
}

resource "aws_iam_role_policy_attachment" "finops_logs" {
  role       = aws_iam_role.finops.name
  policy_arn = "${local.arn}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
