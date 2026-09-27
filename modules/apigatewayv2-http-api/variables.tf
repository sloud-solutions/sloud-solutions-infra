variable "name" {
  type = string
}

variable "cognito_user_pool_client_id" {
  type = string
}

variable "cognito_issuer_url" {
  type = string
}

variable "cors_allowed_origins" {
  type = list(string)
}

variable "routes" {
  description = <<-EOT
    One entry per route. `route_key` is e.g. "GET /expenses". Routes sharing the
    same `lambda_function_name` reuse a single integration + permission.
  EOT
  type = list(object({
    route_key            = string
    lambda_invoke_arn    = string
    lambda_function_name = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
