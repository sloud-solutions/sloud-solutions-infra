
# GitHub Actions OIDC identity provider.
module "github_oidc_provider" {
  source = "../modules/github-oidc-provider"
}

# Plan role: read-only on AWS; may only touch state and lock files.
data "aws_iam_policy_document" "plan" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [module.state_bucket.arn]
  }

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${module.state_bucket.arn}/*"]
  }

  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.state_bucket.arn}/*.tflock"]
  }
}

module "plan_role" {
  source = "../modules/github-oidc-role"

  name                = "${var.project}-tf-plan"
  oidc_provider_arn   = module.github_oidc_provider.arn
  subjects            = ["repo:${local.repo}:pull_request"]
  managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  inline_policy_json  = data.aws_iam_policy_document.plan.json
}

# Apply role: only assumable from the protected GitHub Environment(s).
data "aws_iam_policy_document" "apply" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [module.state_bucket.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.state_bucket.arn}/*"]
  }

  statement {
    sid       = "ManageSiteServices"
    actions   = ["s3:*", "cloudfront:*", "route53:*", "acm:*"]
    resources = ["*"]
  }

  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-*"]
  }

  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
}

module "apply_role" {
  source = "../modules/github-oidc-role"

  name              = "${var.project}-tf-apply"
  oidc_provider_arn = module.github_oidc_provider.arn
  subjects          = [for e in var.github.apply_environments : "repo:${local.repo}:environment:${e}"]

  inline_policy_json = data.aws_iam_policy_document.apply.json
}

# Terraform state bucket. Versions are kept forever; force_destroy stays false so
# a non-empty state bucket cannot be destroyed by accident.
module "state_bucket" {
  source = "../modules/s3-bucket"

  bucket_name = var.backend.bucket
}
