variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS version. Keep within standard support (extended support costs 6x)."
  type        = string
  default     = "1.35"
}

variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS control plane (LabRole in AWS Academy)."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for worker nodes (LabRole in AWS Academy)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for nodes."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets (load balancers)."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (your IP /32)."
  type        = list(string)
  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not expose the EKS API to 0.0.0.0/0; use your IP /32."
  }
}

variable "kms_key_arn" {
  description = "KMS key for Secrets envelope encryption, logs and node volumes."
  type        = string
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "SPOT"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_instance_types" {
  description = "Instance types for the node group (several improve SPOT availability)."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_desired" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "node_min" {
  description = "Minimum node count (0 allows scale-to-zero)."
  type        = number
  default     = 0
}

variable "node_max" {
  description = "Maximum node count."
  type        = number
  default     = 3
}

variable "node_disk_gb" {
  description = "Node root volume size."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  description = "Control-plane log retention."
  type        = number
  default     = 7
}

variable "enable_irsa" {
  description = "Create OIDC provider + app IRSA role (needs IAM write; false in AWS Academy)."
  type        = bool
  default     = false
}

variable "app_namespace" {
  description = "Namespace of the app service account (IRSA)."
  type        = string
  default     = "sentinelops"
}

variable "app_service_account" {
  description = "App service account name (IRSA)."
  type        = string
  default     = "sentinelops-app"
}

variable "app_secret_arn" {
  description = "Secrets Manager secret the app role may read (IRSA)."
  type        = string
  default     = ""
}

variable "jenkins_role_arn" {
  description = "Role granted cluster-admin via access entry. Null in lab mode (LabRole is already the node role)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags propagated to node instances and volumes."
  type        = map(string)
  default     = {}
}
