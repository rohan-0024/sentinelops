# One-time bootstrap of the remote-state backend (local state for this root only).
#   cd terraform/bootstrap && terraform init && terraform apply   # owner confirms
# Then copy the outputs into terraform/envs/aws/backend.hcl.

terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.80.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project      = "sentinelops"
      Owner        = var.owner
      Environment  = "shared"
      ManagedBy    = "terraform"
      AutoTeardown = "false"
    }
  }
}

data "aws_caller_identity" "current" {}

module "state_backend" {
  source          = "../modules/state-backend"
  bucket_name     = "sentinelops-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table_name = "sentinelops-tf-locks"
  force_destroy   = var.force_destroy
}

variable "region" {
  description = "AWS region (AWS Academy: us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "rohan-0024"
}

variable "force_destroy" {
  description = "Allow deleting a non-empty state bucket (true for lab accounts that get wiped)."
  type        = bool
  default     = true
}

output "backend_hcl" {
  description = "Paste into terraform/envs/aws/backend.hcl."
  value       = <<-EOT
    bucket         = "${module.state_backend.bucket_name}"
    key            = "sentinelops/aws/terraform.tfstate"
    region         = "${var.region}"
    dynamodb_table = "${module.state_backend.lock_table_name}"
    encrypt        = true
  EOT
}
