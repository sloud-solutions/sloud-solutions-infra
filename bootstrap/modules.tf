
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

  # Added for the sloud-solutions-tools backend (Lambda + DynamoDB + Cognito +
  # API Gateway). Broad service-level actions on "*", matching the existing
  # ManageSiteServices statement's style, rather than enumerating every ARN.
  statement {
    sid       = "ManageToolsServices"
    actions   = ["lambda:*", "dynamodb:*", "cognito-idp:*", "apigateway:*", "logs:*"]
    resources = ["*"]
  }

  # Lets Terraform attach the Lambda execution roles it creates (under
  # role/${var.project}-*, already covered by ManageProjectRoles above) to the
  # Lambda functions it also creates.
  statement {
    sid       = "PassLambdaExecRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-*"]
  }

  # AWS Budgets has no resource-level ARNs to scope to -- account-wide by
  # design, consistent with a budget alert covering total account spend.
  statement {
    sid       = "ManageBudgets"
    actions   = ["budgets:*"]
    resources = ["*"]
  }

  # EventBridge Scheduler (the cost-poller schedule) and SES (the website's
  # domain identity/DKIM + notification sending) -- added late, after their
  # respective stacks already existed, so CI's applies for both have been
  # silently failing on refresh/plan (AccessDenied) ever since. Local applies
  # worked around it using a broader personal AWS profile.
  statement {
    sid       = "ManageScheduler"
    actions   = ["scheduler:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ManageSES"
    actions   = ["ses:*"]
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
