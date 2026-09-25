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
