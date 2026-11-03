variable "name" {
  description = "Name prefix for IAM resources."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (scopes EKS permissions)."
  type        = string
}

variable "kms_key_arn" {
  description = "Environment KMS key (Lambda env vars and DLQ)."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository Jenkins may push to."
  type        = string
}
