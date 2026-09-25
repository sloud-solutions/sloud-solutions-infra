variable "project" {
  type = string
}

variable "aws" {
  type = object({
    region = string
  })
}

variable "backend" {
  type = object({
    bucket = string
  })
}

variable "github" {
  type = object({
    org                = string
    org_id             = string
    infra_repo         = string
    infra_repo_id      = string
    apply_environments = list(string)
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}
