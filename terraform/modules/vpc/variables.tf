variable "name" {
  description = "Name prefix for VPC resources."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for subnet discovery tags."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR."
  type        = string
  default     = "10.40.0.0/16"
}

variable "azs" {
  description = "Availability zones to use (first az_count are taken)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "az_count" {
  description = "Number of AZs (EKS needs at least 2)."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = "Create a single NAT gateway for private subnets (~USD 0.045/h). Required for private nodes."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Optional KMS key for flow-log bucket encryption."
  type        = string
  default     = null
}

variable "flow_log_retention_days" {
  description = "Days to keep VPC flow logs."
  type        = number
  default     = 7
}
