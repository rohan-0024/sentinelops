# SentinelOps AWS environment.
# lab_mode = true  -> AWS Academy Learner Lab: reuse LabRole / LabInstanceProfile, no IRSA.
# lab_mode = false -> standard account: dedicated least-privilege roles + IRSA.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name         = var.name
  cluster_name = "${var.name}-eks"
  tags = {
    Project      = "sentinelops"
    Owner        = var.owner
    Environment  = var.environment
    ManagedBy    = "terraform"
    AutoTeardown = "true"
    CostCenter   = "academic"
  }
}

# ---------------- KMS (one CMK for the environment) ----------------
data "aws_iam_policy_document" "kms" {
  # checkov:skip=CKV_AWS_111:Key policy - "*" resource means this key only (AWS key-policy semantics)
  # checkov:skip=CKV_AWS_356:Key policy - "*" resource means this key only (AWS key-policy semantics)
  # checkov:skip=CKV_AWS_109:Root-account admin statement is required so the key never becomes unmanageable
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "FlowLogDelivery"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${local.name} environment key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------------- Roles: LabRole (lab) or dedicated (standard) ----------------
data "aws_iam_role" "lab" {
  count = var.lab_mode ? 1 : 0
  name  = "LabRole"
}

module "iam" {
  count              = var.lab_mode ? 0 : 1
  source             = "../../modules/iam"
  name               = local.name
  cluster_name       = local.cluster_name
  ecr_repository_arn = module.ecr.repository_arn
  kms_key_arn        = aws_kms_key.main.arn
}

locals {
  lab_role_arn          = var.lab_mode ? data.aws_iam_role.lab[0].arn : null
  cluster_role_arn      = var.lab_mode ? local.lab_role_arn : module.iam[0].eks_cluster_role_arn
  node_role_arn         = var.lab_mode ? local.lab_role_arn : module.iam[0].eks_node_role_arn
  finops_role_arn       = var.lab_mode ? local.lab_role_arn : module.iam[0].finops_lambda_role_arn
  jenkins_profile_name  = var.lab_mode ? "LabInstanceProfile" : module.iam[0].jenkins_instance_profile_name
  jenkins_access_entry  = var.lab_mode ? null : module.iam[0].jenkins_role_arn
}

# ---------------- Network, registry, cluster ----------------
module "vpc" {
  source       = "../../modules/vpc"
  name         = local.name
  cluster_name = local.cluster_name
  cidr_block   = var.vpc_cidr
  azs          = var.azs
  kms_key_arn  = aws_kms_key.main.arn
}

module "ecr" {
  source      = "../../modules/ecr"
  name        = "${local.name}-app"
  kms_key_arn = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret" "app" {
  # checkov:skip=CKV2_AWS_57:Demo secret has no rotation Lambda; rotation is documented in the runbook
  name                    = "${local.name}/app"
  description             = "Runtime config for the sample app (read via IRSA on standard accounts)"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0
}

module "eks" {
  source              = "../../modules/eks"
  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  cluster_role_arn    = local.cluster_role_arn
  node_role_arn       = local.node_role_arn
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  public_access_cidrs = var.admin_cidrs
  kms_key_arn         = aws_kms_key.main.arn
  capacity_type       = var.node_capacity_type
  node_instance_types = var.node_instance_types
  node_desired        = var.node_desired
  enable_irsa         = !var.lab_mode
  app_secret_arn      = aws_secretsmanager_secret.app.arn
  jenkins_role_arn    = local.jenkins_access_entry
  tags                = local.tags
}

module "jenkins" {
  count                 = var.create_jenkins_ec2 ? 1 : 0
  source                = "../../modules/jenkins-ec2"
  name                  = local.name
  vpc_id                = module.vpc.vpc_id
  subnet_id             = module.vpc.public_subnet_ids[0]
  admin_cidrs           = var.admin_cidrs
  instance_type         = var.jenkins_instance_type
  instance_profile_name = local.jenkins_profile_name
  key_name              = var.key_name
  kms_key_arn           = aws_kms_key.main.arn
}

module "finops" {
  source              = "../../modules/finops"
  name                = local.name
  lambda_role_arn     = local.finops_role_arn
  handler_source_file = "${path.root}/../../../tools/finops/handler.py"
  cluster_name        = module.eks.cluster_name
  nodegroup_name      = module.eks.node_group_name
  default_desired     = var.node_desired
  kms_key_arn         = aws_kms_key.main.arn
  enable_auto_start   = var.finops_auto_start
}
