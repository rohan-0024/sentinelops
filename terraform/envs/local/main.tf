# LOCAL MODE: the same state-backend and FinOps modules applied to LocalStack
# (Community edition) - zero cost, safe to `apply`. EKS/ECR are LocalStack Pro
# features, so the cluster in local mode is kind (see scripts/kind-up.sh).
#   make tf-local    (starts LocalStack, terraform init + apply here)

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.80.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.0"
    }
  }
}

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint."
  type        = string
  default     = "http://localhost:4566"
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test" # LocalStack dummy credentials, not a secret
  secret_key                  = "test" # checkov:skip=CKV_AWS_41:LocalStack dummy credentials
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3             = var.localstack_endpoint
    dynamodb       = var.localstack_endpoint
    lambda         = var.localstack_endpoint
    iam            = var.localstack_endpoint
    sts            = var.localstack_endpoint
    ssm            = var.localstack_endpoint
    sqs            = var.localstack_endpoint
    kms            = var.localstack_endpoint
    cloudwatchlogs = var.localstack_endpoint
    cloudwatch     = var.localstack_endpoint
    events         = var.localstack_endpoint
    secretsmanager = var.localstack_endpoint
  }

  default_tags {
    tags = {
      Project      = "sentinelops"
      Environment  = "local"
      ManagedBy    = "terraform"
      AutoTeardown = "true"
    }
  }
}

resource "aws_kms_key" "local" {
  # checkov:skip=CKV2_AWS_64:LocalStack emulated key; default policy is fine for local mode
  description         = "sentinelops local key"
  enable_key_rotation = true
}

module "state_backend" {
  source          = "../../modules/state-backend"
  bucket_name     = "sentinelops-tfstate-local"
  lock_table_name = "sentinelops-tf-locks-local"
  force_destroy   = true
}

# LocalStack accepts any role ARN; this mirrors LabRole in AWS Academy.
module "finops" {
  source              = "../../modules/finops"
  name                = "sentinelops-local"
  lambda_role_arn     = "arn:aws:iam::000000000000:role/LabRole"
  handler_source_file = "${path.root}/../../../tools/finops/handler.py"
  cluster_name        = "sentinelops-kind"
  nodegroup_name      = "kind-workers"
  kms_key_arn         = aws_kms_key.local.arn
  dry_run             = true
}

output "state_bucket" {
  description = "Local state bucket."
  value       = module.state_backend.bucket_name
}

output "finops_lambda" {
  description = "FinOps Lambda deployed to LocalStack."
  value       = module.finops.lambda_name
}
