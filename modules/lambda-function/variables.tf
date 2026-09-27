variable "name" {
  description = "Function name (also used to derive the IAM role and log group names)."
  type        = string
}

variable "handler" {
  type    = string
  default = "index.handler"
}

variable "runtime" {
  type    = string
  default = "nodejs22.x"
}

variable "source_dir" {
  description = "Directory containing the function's source; zipped by this module."
  type        = string
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "inline_policy_json" {
  description = "IAM policy document (JSON) granting this function's execution role its permissions."
  type        = string
}

variable "timeout" {
  type    = number
  default = 10
}

variable "memory_size" {
  type    = number
  default = 128
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
