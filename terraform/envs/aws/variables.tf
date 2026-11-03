variable "region" {
  description = "AWS region (AWS Academy Learner Lab: us-east-1 or us-west-2)."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "sentinelops"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "rohan-0024"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "demo"
}

variable "lab_mode" {
  description = "true for AWS Academy Learner Lab (reuse LabRole, no IRSA); false for a standard account."
  type        = bool
  default     = true
}

variable "admin_cidrs" {
  description = "Your public IP as /32 (curl -s https://checkip.amazonaws.com). Used for EKS API and Jenkins SG."
  type        = list(string)
}

variable "key_name" {
  description = "EC2 key pair for the Jenkins host (AWS Academy provides 'vockey')."
  type        = string
  default     = "vockey"
}

variable "azs" {
  description = "Availability zones (must be EKS-supported in the region)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS version (1.35: standard support until 2027-03-27)."
  type        = string
  default     = "1.35"
}

variable "node_capacity_type" {
  description = "SPOT (cheapest) or ON_DEMAND."
  type        = string
  default     = "SPOT"
}

variable "node_instance_types" {
  description = "Node instance types."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_desired" {
  description = "Desired nodes."
  type        = number
  default     = 2
}

variable "create_jenkins_ec2" {
  description = "Create the Jenkins/SonarQube EC2 host."
  type        = bool
  default     = true
}

variable "jenkins_instance_type" {
  description = "Jenkins host type."
  type        = string
  default     = "t3.large"
}

variable "finops_auto_start" {
  description = "Enable scheduled morning start (teardown is always scheduled)."
  type        = bool
  default     = false
}
