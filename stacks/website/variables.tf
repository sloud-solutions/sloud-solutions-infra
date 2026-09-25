variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws" {
  type = object({
    region = string
  })
}

variable "github" {
  type = object({
    org           = string
    infra_repo    = string
    site_repo     = string
    deploy_branch = string
  })
}

variable "website" {
  type = object({
    domain_name         = optional(string)
    include_www         = bool
    price_class         = string
    default_root_object = string
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Injected at run time by the workflow (TF_VAR_git_sha), not from JSON.
variable "git_sha" {
  type    = string
  default = "local"
}
