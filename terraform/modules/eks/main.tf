# EKS cluster + one managed node group (small, SPOT by default, scalable to zero),
# KMS envelope encryption of Secrets, full control-plane logging, IMDSv2-only
# nodes, and optional IRSA (OIDC provider + app role reading one secret).

resource "aws_cloudwatch_log_group" "cluster" {
  # checkov:skip=CKV_AWS_338:1-year retention is a cost burden for a lab; 7 days is enough for the demo
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_eks_cluster" "this" {
  # checkov:skip=CKV_AWS_38:public_access_cidrs comes from a variable whose validation rejects 0.0.0.0/0; checkov cannot evaluate it
  # checkov:skip=CKV_AWS_39:Public endpoint is required to reach the API from a laptop without a VPN; restricted to var.public_access_cidrs
  name                      = var.cluster_name
  version                   = var.kubernetes_version
  role_arn                  = var.cluster_role_arn
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.kms_key_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.cluster]
}

resource "aws_launch_template" "nodes" {
  # checkov:skip=CKV_AWS_341:Hop limit 2 is the EKS default; Kyverno/aws-node fetch ECR credentials via IMDS in lab mode (no IRSA)
  name_prefix            = "${var.cluster_name}-nodes-"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.node_disk_gb
      volume_type = "gp3"
      encrypted   = true
      # AWS-managed EBS key on purpose: a CMK would need a key-policy grant for the
      # AutoScaling service-linked role, which may not exist yet in a fresh account.
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-node" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids
  capacity_type   = var.capacity_type
  instance_types  = var.node_instance_types
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  labels = {
    workload = "general"
  }

  # The FinOps autopilot changes desired/min size out-of-band; don't fight it.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size, scaling_config[0].min_size]
  }
}

# ---------------- IRSA (standard accounts only) ----------------
data "tls_certificate" "oidc" {
  count = var.enable_irsa ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  count           = var.enable_irsa ? 1 : 0
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]
}

locals {
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_iam_policy_document" "app_irsa_assume" {
  count = var.enable_irsa ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${var.app_namespace}:${var.app_service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_irsa" {
  count              = var.enable_irsa ? 1 : 0
  name               = "${var.cluster_name}-app-irsa"
  assume_role_policy = data.aws_iam_policy_document.app_irsa_assume[0].json
}

data "aws_iam_policy_document" "app_irsa" {
  count = var.enable_irsa ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.app_secret_arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "app_irsa" {
  count  = var.enable_irsa ? 1 : 0
  name   = "read-app-secret"
  role   = aws_iam_role.app_irsa[0].id
  policy = data.aws_iam_policy_document.app_irsa[0].json
}

# Grants the Jenkins role cluster-admin through an EKS access entry (standard accounts).
resource "aws_eks_access_entry" "jenkins" {
  count         = var.jenkins_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.jenkins_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins" {
  count         = var.jenkins_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.jenkins_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.jenkins]
}
