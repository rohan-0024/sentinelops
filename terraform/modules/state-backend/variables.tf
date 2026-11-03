variable "bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for state locking."
  type        = string
  default     = "sentinelops-tf-locks"
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN. Null uses AWS-managed encryption."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow destroying the bucket while it still holds state (true only for throwaway labs)."
  type        = bool
  default     = false
}
