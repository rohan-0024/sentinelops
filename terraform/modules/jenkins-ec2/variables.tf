variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet for the Jenkins host."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH/Jenkins/SonarQube (your IP /32)."
  type        = list(string)
  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Do not open Jenkins to the internet; use your IP /32."
  }
}

variable "instance_type" {
  description = "t3.large: Jenkins + SonarQube need ~6 GB RAM."
  type        = string
  default     = "t3.large"
}

variable "instance_profile_name" {
  description = "Instance profile (LabInstanceProfile in AWS Academy)."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair for Ansible SSH (vockey in AWS Academy)."
  type        = string
}

variable "disk_gb" {
  description = "Root volume size."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "KMS key for the root volume."
  type        = string
  default     = null
}
