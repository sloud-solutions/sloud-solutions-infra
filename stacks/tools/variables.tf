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
    org                 = string
    org_id              = string
    infra_repo          = string
    tools_repo          = string
    tools_repo_id       = string
    tools_deploy_branch = string
  })
}

variable "tools" {
  type = object({
    domain_name         = optional(string)
    dns_provider        = optional(string, "external")
    attach_domain       = optional(bool, false)
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
