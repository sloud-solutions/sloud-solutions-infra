# One-time, admin-run stack (short-lived SSO credentials, local state).
# Creates what the pipeline itself depends on:
#   modules.tf  state bucket, GitHub OIDC provider, plan/apply roles (all via ../modules)
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repo       = "${var.github.org}@${var.github.org_id}/${var.github.infra_repo}@${var.github.infra_repo_id}"
}
