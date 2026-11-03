variable "name" {
  description = "Name prefix."
  type        = string
}

variable "lambda_role_arn" {
  description = "Execution role ARN (LabRole in AWS Academy)."
  type        = string
}

variable "handler_source_file" {
  description = "Path to tools/finops/handler.py."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster to scale."
  type        = string
}

variable "nodegroup_name" {
  description = "Node group to scale to zero."
  type        = string
}

variable "default_desired" {
  description = "Node count restored by the start action when no previous value is stored."
  type        = number
  default     = 2
}

variable "instance_ids" {
  description = "Optional allow-list of instance IDs; empty means every Schedule=office-hours instance."
  type        = list(string)
  default     = []
}

variable "stop_cron" {
  description = "UTC cron for teardown. Default 14:30 UTC = 20:00 IST, every day."
  type        = string
  default     = "30 14 * * ? *"
}

variable "start_cron" {
  description = "UTC cron for start. Default 03:30 UTC = 09:00 IST, Mon-Fri."
  type        = string
  default     = "30 3 ? * MON-FRI *"
}

variable "enable_auto_start" {
  description = "Enable the scheduled start rule (off by default: start manually when needed)."
  type        = bool
  default     = false
}

variable "reserved_concurrency" {
  description = "Reserved concurrency. -1 = unreserved (AWS Academy accounts have a concurrency limit of 10, so reserving fails)."
  type        = number
  default     = -1
}

variable "dry_run" {
  description = "Log actions without changing anything."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "KMS key for env vars, logs and DLQ."
  type        = string
}
