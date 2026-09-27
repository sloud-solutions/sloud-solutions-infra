data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # Keeps the required `sloud-website-*` IAM-role-naming prefix that
  # bootstrap's ManageProjectRoles statement is scoped to (var.project is
  # literally "sloud-website", shared across both stacks) — just adds a
  # "-tools-" segment for this stack's own resources.
  name = "${var.project}-tools-${var.environment}"

  domain_name = var.tools.domain_name
  use_domain  = local.domain_name != null
  use_route53 = local.use_domain && var.tools.dns_provider == "route53"

  # Phase 1 (attach_domain = false): only request the certificate.
  # Phase 2 (attach_domain = true): wait for it to be issued, then serve the domain.
  attach = local.use_domain && var.tools.attach_domain

  domain_names = local.use_domain ? compact([
    local.domain_name,
    var.tools.include_www ? "www.${local.domain_name}" : null,
  ]) : []
  aliases = local.attach ? local.domain_names : []

  site_url = local.attach ? "https://${local.domain_name}" : "https://${module.cloudfront.domain_name}"

  common_env = {
    EXPENSES_TABLE        = module.expenses_table.name
    EMPLOYEES_TABLE       = module.employees_table.name
    EMPLOYEES_EMAIL_INDEX = "byEmail"
  }
}

# --- Custom domain (only when tools.domain_name is set) ----------------------

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

# --- Static hosting for the tools app itself ---------------------------------

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
  price_class                 = var.tools.price_class
  default_root_object         = var.tools.default_root_object
}

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
  subjects          = ["repo:${var.github.org}@${var.github.org_id}/${var.github.tools_repo}@${var.github.tools_repo_id}:ref:refs/heads/${var.github.tools_deploy_branch}"]

  inline_policy_json = data.aws_iam_policy_document.site_deploy.json
}

# --- Employee photos: their own bucket + a second, separate CloudFront -------
# distribution (deliberately not a second origin on the main site's
# distribution, to avoid modifying the shared `cloudfront` module).

module "photos_bucket" {
  source = "../../modules/s3-site-bucket"

  bucket_name                 = "${local.name}-photos-${data.aws_caller_identity.current.account_id}"
  cloudfront_distribution_arn = module.photos_cloudfront.arn
}

module "photos_cloudfront" {
  source = "../../modules/cloudfront"

  name                        = "${local.name}-photos"
  bucket_regional_domain_name = module.photos_bucket.bucket_regional_domain_name
  default_root_object         = ""
}

# --- Data -----------------------------------------------------------------

module "expenses_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-expenses"
  tags       = var.tags
}

module "employees_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-employees"
  tags       = var.tags

  extra_attributes         = [{ name = "email", type = "S" }]
  global_secondary_indexes = [{ name = "byEmail", hash_key = "email", projection_type = "ALL" }]
}

# --- Auth ---------------------------------------------------------------

module "user_pool" {
  source     = "../../modules/cognito-user-pool"
  name       = local.name
  aws_region = var.aws.region
  tags       = var.tags
}

# --- Lambdas ---------------------------------------------------------------
# Each function's execution role is scoped to only the table(s)/bucket it
# actually needs; every non-seed function also needs to Query the employees
# email index to resolve the caller's role/access (see lambda-src/*/access.mjs).

data "aws_iam_policy_document" "read_caller_access" {
  statement {
    actions   = ["dynamodb:Query"]
    resources = [module.employees_table.arn, "${module.employees_table.arn}/index/*"]
  }
}

data "aws_iam_policy_document" "expenses_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:Scan"]
    resources = [module.expenses_table.arn]
  }
}

module "lambda_expenses_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-expenses-list"
  source_dir            = "${path.module}/lambda-src/expenses-list"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.expenses_list.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "expenses_write" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [module.expenses_table.arn]
  }
}

module "lambda_expenses_write" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-expenses-write"
  source_dir            = "${path.module}/lambda-src/expenses-write"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.expenses_write.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "employees_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:Scan"]
    resources = [module.employees_table.arn]
  }
}

module "lambda_employees_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-employees-list"
  source_dir            = "${path.module}/lambda-src/employees-list"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.employees_list.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "employees_write" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Scan"]
    resources = [module.employees_table.arn]
  }
  statement {
    actions = [
      "cognito-idp:AdminEnableUser",
      "cognito-idp:AdminDisableUser",
      "cognito-idp:AdminUserGlobalSignOut",
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:AdminRemoveUserFromGroup",
    ]
    resources = [module.user_pool.user_pool_arn]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.photos_bucket.arn}/*"]
  }
}

module "lambda_employees_write" {
  source     = "../../modules/lambda-function"
  name       = "${local.name}-employees-write"
  source_dir = "${path.module}/lambda-src/employees-write"
  environment_variables = merge(local.common_env, {
    USER_POOL_ID  = module.user_pool.user_pool_id
    PHOTOS_BUCKET = module.photos_bucket.id
    PHOTOS_DOMAIN = module.photos_cloudfront.domain_name
  })
  inline_policy_json = data.aws_iam_policy_document.employees_write.json
  tags               = var.tags
}

data "aws_iam_policy_document" "admin_create_user" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [module.employees_table.arn]
  }
  statement {
    actions   = ["cognito-idp:AdminCreateUser", "cognito-idp:AdminSetUserPassword", "cognito-idp:AdminAddUserToGroup"]
    resources = [module.user_pool.user_pool_arn]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.photos_bucket.arn}/*"]
  }
}

module "lambda_admin_create_user" {
  source     = "../../modules/lambda-function"
  name       = "${local.name}-admin-create-user"
  source_dir = "${path.module}/lambda-src/admin-create-user"
  environment_variables = merge(local.common_env, {
    USER_POOL_ID  = module.user_pool.user_pool_id
    PHOTOS_BUCKET = module.photos_bucket.id
    PHOTOS_DOMAIN = module.photos_cloudfront.domain_name
  })
  inline_policy_json = data.aws_iam_policy_document.admin_create_user.json
  tags               = var.tags
}

data "aws_iam_policy_document" "admin_reset_password" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["cognito-idp:AdminSetUserPassword"]
    resources = [module.user_pool.user_pool_arn]
  }
}

module "lambda_admin_reset_password" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-admin-reset-password"
  source_dir            = "${path.module}/lambda-src/admin-reset-password"
  environment_variables = merge(local.common_env, { USER_POOL_ID = module.user_pool.user_pool_id })
  inline_policy_json    = data.aws_iam_policy_document.admin_reset_password.json
  tags                  = var.tags
}

module "lambda_me" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-me"
  source_dir            = "${path.module}/lambda-src/me"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.read_caller_access.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "seed" {
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [module.expenses_table.arn, module.employees_table.arn]
  }
}

# Deployed but deliberately not wired into http_api's routes below — invoked
# once manually after first deploy (`aws lambda invoke ...`), see the runbook.
module "lambda_seed" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-seed"
  source_dir            = "${path.module}/lambda-src/seed"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.seed.json
  tags                  = var.tags
}

# --- API ---------------------------------------------------------------

module "http_api" {
  source = "../../modules/apigatewayv2-http-api"

  name                        = local.name
  cognito_user_pool_client_id = module.user_pool.client_id
  cognito_issuer_url          = module.user_pool.issuer_url
  cors_allowed_origins        = [local.site_url]
  tags                        = var.tags

  routes = [
    { route_key = "GET /expenses", lambda_invoke_arn = module.lambda_expenses_list.invoke_arn, lambda_function_name = module.lambda_expenses_list.name },
    { route_key = "POST /expenses", lambda_invoke_arn = module.lambda_expenses_write.invoke_arn, lambda_function_name = module.lambda_expenses_write.name },
    { route_key = "DELETE /expenses/{id}", lambda_invoke_arn = module.lambda_expenses_write.invoke_arn, lambda_function_name = module.lambda_expenses_write.name },
    { route_key = "GET /employees", lambda_invoke_arn = module.lambda_employees_list.invoke_arn, lambda_function_name = module.lambda_employees_list.name },
    { route_key = "DELETE /employees/{id}", lambda_invoke_arn = module.lambda_employees_write.invoke_arn, lambda_function_name = module.lambda_employees_write.name },
    { route_key = "PATCH /employees/{id}", lambda_invoke_arn = module.lambda_employees_write.invoke_arn, lambda_function_name = module.lambda_employees_write.name },
    { route_key = "POST /admin/users", lambda_invoke_arn = module.lambda_admin_create_user.invoke_arn, lambda_function_name = module.lambda_admin_create_user.name },
    { route_key = "POST /admin/reset-password", lambda_invoke_arn = module.lambda_admin_reset_password.invoke_arn, lambda_function_name = module.lambda_admin_reset_password.name },
    { route_key = "GET /me", lambda_invoke_arn = module.lambda_me.invoke_arn, lambda_function_name = module.lambda_me.name },
  ]
}
