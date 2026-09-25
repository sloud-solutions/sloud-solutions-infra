data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  name        = "${var.project}-${var.environment}"
  domain_name = var.website.domain_name
  use_domain  = local.domain_name != null

  aliases = local.use_domain ? compact([
    local.domain_name,
    var.website.include_www ? "www.${local.domain_name}" : null,
  ]) : []
}

# --- Custom domain (only when website.domain_name is set) -------------------

module "dns_zone" {
  count  = local.use_domain ? 1 : 0
  source = "../../modules/route53-zone"

  domain_name = local.domain_name
}

module "certificate" {
  count  = local.use_domain ? 1 : 0
  source = "../../modules/acm-certificate"

  domain_name               = local.domain_name
  subject_alternative_names = slice(local.aliases, 1, length(local.aliases))
  zone_id                   = module.dns_zone[0].zone_id
}

module "dns_records" {
  count  = local.use_domain ? 1 : 0
  source = "../../modules/route53-records"

  zone_id                   = module.dns_zone[0].zone_id
  names                     = local.aliases
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
  acm_certificate_arn         = local.use_domain ? module.certificate[0].arn : null
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
  subjects          = ["repo:${var.github.org}/${var.github.site_repo}:ref:refs/heads/${var.github.deploy_branch}"]

  inline_policy_json = data.aws_iam_policy_document.site_deploy.json
}
