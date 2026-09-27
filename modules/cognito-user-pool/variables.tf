variable "name" {
  description = "User pool name."
  type        = string
}

variable "aws_region" {
  description = "Region the pool is created in, used to build the issuer URL output."
  type        = string
}

variable "password_minimum_length" {
  type    = number
  default = 8
}

variable "mfa_configuration" {
  description = "OFF for this small, low-risk internal tool."
  type        = string
  default     = "OFF"
}

variable "explicit_auth_flows" {
  type    = list(string)
  default = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

variable "access_token_validity_minutes" {
  type    = number
  default = 60
}

variable "refresh_token_validity_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
