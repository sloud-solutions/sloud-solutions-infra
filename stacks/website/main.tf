data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  name        = "${var.project}-${var.environment}"
  domain_name = var.website.domain_name
  use_domain  = local.domain_name != null
  use_route53 = local.use_domain && var.website.dns_provider == "route53"

  # Phase 1 (attach_domain = false): only request the certificate.
  # Phase 2 (attach_domain = true): wait for it to be issued, then serve the domain.
  attach = local.use_domain && var.website.attach_domain

  domain_names = local.use_domain ? compact([
    local.domain_name,
    var.website.include_www ? "www.${local.domain_name}" : null,
  ]) : []
  aliases = local.attach ? local.domain_names : []
}

# --- Custom domain (only when website.domain_name is set) -------------------
# DNS is either Route 53 (dns_provider = "route53") or external, e.g. Cloudflare
# (records added by hand from the outputs).

module "dns_zone" {
  count  = local.use_route53 ? 1 : 0
  source = "../../modules/route53-zone"

  domain_name = local.domain_name
}

module "certificate" {
  count  = local.use_domain ? 1 : 0
  source = "../../modules/acm-certificate"

  domain_name               = local.domain_name
  subject_alternative_names = slice(local.domain_names, 1, length(local.domain_names))
  zone_id                   = local.use_route53 ? module.dns_zone[0].zone_id : null
  wait_for_validation       = local.attach
}

module "dns_records" {
  count  = local.use_route53 && local.attach ? 1 : 0
  source = "../../modules/route53-records"

  zone_id                   = module.dns_zone[0].zone_id
  names                     = local.domain_names
  cloudfront_domain_name    = module.cloudfront.domain_name
  cloudfront_hosted_zone_id = module.cloudfront.hosted_zone_id
}

# --- Hosting -----------------------------------------------------------------

module "site_bucket" {
  source = "../../modules/s3-site-bucket"

  bucket_name                 = "${local.name}-site-${data.aws_caller_identity.current.account_id}"
  cloudfront_distribution_arn = module.cloudfront.arn
}

module "cloudfront" {
  source = "../../modules/cloudfront"

  name                        = local.name
  bucket_regional_domain_name = module.site_bucket.bucket_regional_domain_name
  aliases                     = local.aliases
  acm_certificate_arn         = local.attach ? module.certificate[0].arn : null
  price_class                 = var.website.price_class
  default_root_object         = var.website.default_root_object
}

# --- Role the website repo assumes (via OIDC) to publish the site -----------

data "aws_iam_policy_document" "site_deploy" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [module.site_bucket.arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.site_bucket.arn}/*"]
  }

  statement {
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [module.cloudfront.arn]
  }
}

module "site_deploy_role" {
  source = "../../modules/github-oidc-role"

  name              = "${local.name}-site-deploy"
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects          = ["repo:${var.github.org}@${var.github.org_id}/${var.github.site_repo}@${var.github.site_repo_id}:ref:refs/heads/${var.github.deploy_branch}"]

  inline_policy_json = data.aws_iam_policy_document.site_deploy.json
}

# --- Careers "Apply" -- resume upload + application capture -----------------
# Public (no login -- applicants don't have an account), separate from the
# tools portal's Cognito-protected API on purpose.

locals {
  # Same value the "site_url" output computes, needed here for CORS.
  site_url = local.attach ? "https://${local.domain_name}" : "https://${module.cloudfront.domain_name}"
  apply_cors_origins = local.use_domain ? compact([
    "https://${local.domain_name}",
    var.website.include_www ? "https://www.${local.domain_name}" : null,
  ]) : [local.site_url]
  notify_email = "info@sloudsolutions.com"
}

module "resumes_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name                        = "${local.name}-resumes-${data.aws_caller_identity.current.account_id}"
  noncurrent_version_expiration_days = 30
}

# Resumes are uploaded straight from the browser via a presigned PUT --
# S3 has no CORS rules by default, so that cross-origin PUT needs this.
resource "aws_s3_bucket_cors_configuration" "resumes" {
  bucket = module.resumes_bucket.id
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = local.apply_cors_origins
    allowed_headers = ["content-type"]
    max_age_seconds = 3000
  }
}

module "applications_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-applications"
  tags       = var.tags
}

# Domain identity + DKIM (instead of a single verified email address) so
# outbound mail is cryptographically signed as genuinely from this domain --
# without it, mail clients have no way to tell it apart from spoofed mail and
# tend to file it as spam. One-time manual step: add the 3 CNAME records in
# `ses_dkim_records_to_add` (output below) at your DNS provider; cannot be
# automated here since DNS is external, not Route 53. Sender and recipient
# are the same verified domain here, so this still works entirely inside the
# SES sandbox -- no production-access request needed.
resource "aws_ses_domain_identity" "notify" {
  domain = local.domain_name
}

resource "aws_ses_domain_dkim" "notify" {
  domain = aws_ses_domain_identity.notify.domain
}

data "aws_iam_policy_document" "apply_presign" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.resumes_bucket.arn}/*"]
  }
}

module "lambda_apply_presign" {
  source     = "../../modules/lambda-function"
  name       = "${local.name}-apply-presign"
  source_dir = "${path.module}/lambda-src/apply-presign"
  environment_variables = {
    RESUMES_BUCKET = module.resumes_bucket.id
  }
  inline_policy_json = data.aws_iam_policy_document.apply_presign.json
  tags               = var.tags
}

data "aws_iam_policy_document" "apply_submit" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${module.resumes_bucket.arn}/*"]
  }
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [module.applications_table.arn]
  }
  statement {
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [aws_ses_domain_identity.notify.arn]
  }
}

module "lambda_apply_submit" {
  source     = "../../modules/lambda-function"
  name       = "${local.name}-apply-submit"
  source_dir = "${path.module}/lambda-src/apply-submit"
  environment_variables = {
    RESUMES_BUCKET     = module.resumes_bucket.id
    APPLICATIONS_TABLE = module.applications_table.name
    NOTIFY_EMAIL       = local.notify_email
  }
  inline_policy_json = data.aws_iam_policy_document.apply_submit.json
  tags               = var.tags
}

resource "aws_apigatewayv2_api" "apply" {
  name          = "${local.name}-apply"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = local.apply_cors_origins
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }

  tags = var.tags
}

resource "aws_apigatewayv2_stage" "apply" {
  api_id      = aws_apigatewayv2_api.apply.id
  name        = "$default"
  auto_deploy = true
  tags        = var.tags
}

resource "aws_apigatewayv2_integration" "apply_presign" {
  api_id                 = aws_apigatewayv2_api.apply.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda_apply_presign.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "apply_presign" {
  api_id             = aws_apigatewayv2_api.apply.id
  route_key          = "POST /apply/presign"
  target             = "integrations/${aws_apigatewayv2_integration.apply_presign.id}"
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "apply_presign" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_apply_presign.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.apply.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "apply_submit" {
  api_id                 = aws_apigatewayv2_api.apply.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda_apply_submit.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "apply_submit" {
  api_id             = aws_apigatewayv2_api.apply.id
  route_key          = "POST /apply/submit"
  target             = "integrations/${aws_apigatewayv2_integration.apply_submit.id}"
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "apply_submit" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_apply_submit.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.apply.execution_arn}/*/*"
}
