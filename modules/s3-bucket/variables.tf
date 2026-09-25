variable "bucket_name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "force_destroy" {
  description = "Allow destroying a non-empty bucket. Keep false for state buckets."
  type        = bool
  default     = false
}

variable "noncurrent_version_expiration_days" {
  description = "Expire old object versions after N days. null keeps them forever."
  type        = number
  default     = null
}

variable "source_policy_documents" {
  description = "Extra bucket policy documents (JSON) merged with the built-in TLS-only deny."
  type        = list(string)
  default     = []
}
