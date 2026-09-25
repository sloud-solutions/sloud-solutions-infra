variable "name" {
  description = "IAM role name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  type        = string
}

variable "subjects" {
  description = "Allowed token `sub` claims, e.g. repo:org/repo:environment:prod."
  type        = list(string)
}

variable "managed_policy_arns" {
  description = "AWS managed policies to attach."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Inline policy document (JSON) granting the role its permissions."
  type        = string
}
