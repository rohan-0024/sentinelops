variable "name" {
  description = "Repository name."
  type        = string
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN; null uses AES256."
  type        = string
  default     = null
}

variable "keep_images" {
  description = "Number of images to retain."
  type        = number
  default     = 20
}

variable "force_delete" {
  description = "Delete the repository even if it contains images (lab teardown)."
  type        = bool
  default     = true
}
