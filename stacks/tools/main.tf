data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Cross-stack read of the website stack's applications table / resumes
# bucket, for the HRMS Resumes admin view below -- both stacks share one S3
# state backend/account, so this needs no cross-account role assumption.
data "terraform_remote_state" "website" {
  backend = "s3"
  config = {
    bucket = "sloud-solutions-tfstate-639793187640"
    key    = "website/prod.tfstate"
    region = "us-east-1"
  }
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
    EXPENSES_TABLE            = module.expenses_table.name
    EMPLOYEES_TABLE           = module.employees_table.name
    EMPLOYEES_EMAIL_INDEX     = "byEmail"
    WORK_BOARDS_TABLE         = module.work_boards_table.name
    WORK_TASKS_TABLE          = module.work_tasks_table.name
    WORK_TASKS_BOARD_INDEX    = "byBoard"
    ATTENDANCE_TABLE          = module.attendance_table.name
    ATTENDANCE_EMPLOYEE_INDEX = "byEmployeeId"
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

# The expense-document upload is the first writer that PUTs to this bucket
# directly from the browser (everything else uploads server-side from a
# Lambda) -- S3 has no CORS rules by default, so that cross-origin PUT needs
# to be explicitly allowed here.
resource "aws_s3_bucket_cors_configuration" "photos" {
  bucket = module.photos_bucket.id
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = [local.site_url]
    allowed_headers = ["content-type"]
    max_age_seconds = 3000
  }
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

module "work_boards_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-work-boards"
  tags       = var.tags
}

module "work_tasks_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-work-tasks"
  tags       = var.tags

  extra_attributes         = [{ name = "boardId", type = "S" }]
  global_secondary_indexes = [{ name = "byBoard", hash_key = "boardId", projection_type = "ALL" }]
}

module "attendance_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-attendance"
  tags       = var.tags

  extra_attributes         = [{ name = "employeeId", type = "S" }]
  global_secondary_indexes = [{ name = "byEmployeeId", hash_key = "employeeId", projection_type = "ALL" }]
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
    actions   = ["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
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

data "aws_iam_policy_document" "expenses_document_presign" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.photos_bucket.arn}/*"]
  }
}

module "lambda_expenses_document_presign" {
  source     = "../../modules/lambda-function"
  name       = "${local.name}-expenses-document-presign"
  source_dir = "${path.module}/lambda-src/expenses-document-presign"
  environment_variables = merge(local.common_env, {
    PHOTOS_BUCKET = module.photos_bucket.id
    PHOTOS_DOMAIN = module.photos_cloudfront.domain_name
  })
  inline_policy_json = data.aws_iam_policy_document.expenses_document_presign.json
  tags               = var.tags
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
    actions   = ["dynamodb:PutItem", "dynamodb:Scan"]
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

# Admin-only: powers the "Cloud Resource Tracker" page, listing every resource
# across the account via Resource Explorer's pre-built index (read-only,
# account-wide -- deliberately not scoped to a single service/resource ARN).
data "aws_iam_policy_document" "cloud_resources_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["resource-explorer-2:Search", "resource-explorer-2:GetIndex"]
    resources = ["*"]
  }
}

module "lambda_cloud_resources_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-cloud-resources-list"
  source_dir            = "${path.module}/lambda-src/cloud-resources-list"
  timeout               = 30
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.cloud_resources_list.json
  tags                  = var.tags
}

# --- HRMS: Resumes -----------------------------------------------------
# Admin-only view over job applications submitted through the website's
# public careers "Apply" form -- the applications table and resumes bucket
# live in the website stack (see data.terraform_remote_state.website above),
# not here.

locals {
  resumes_env = {
    APPLICATIONS_TABLE = data.terraform_remote_state.website.outputs.applications_table_name
    RESUMES_BUCKET     = data.terraform_remote_state.website.outputs.resumes_bucket_name
  }
}

data "aws_iam_policy_document" "resumes_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:Scan"]
    resources = [data.terraform_remote_state.website.outputs.applications_table_arn]
  }
}

module "lambda_resumes_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-resumes-list"
  source_dir            = "${path.module}/lambda-src/resumes-list"
  environment_variables = merge(local.common_env, local.resumes_env)
  inline_policy_json    = data.aws_iam_policy_document.resumes_list.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "resumes_resume_url" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [data.terraform_remote_state.website.outputs.applications_table_arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${data.terraform_remote_state.website.outputs.resumes_bucket_arn}/*"]
  }
}

module "lambda_resumes_resume_url" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-resumes-resume-url"
  source_dir            = "${path.module}/lambda-src/resumes-resume-url"
  environment_variables = merge(local.common_env, local.resumes_env)
  inline_policy_json    = data.aws_iam_policy_document.resumes_resume_url.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "resumes_write" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
    resources = [data.terraform_remote_state.website.outputs.applications_table_arn]
  }
  statement {
    actions   = ["s3:DeleteObject"]
    resources = ["${data.terraform_remote_state.website.outputs.resumes_bucket_arn}/*"]
  }
}

module "lambda_resumes_write" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-resumes-write"
  source_dir            = "${path.module}/lambda-src/resumes-write"
  environment_variables = merge(local.common_env, local.resumes_env)
  inline_policy_json    = data.aws_iam_policy_document.resumes_write.json
  tags                  = var.tags
}

# --- Cost summary widget ----------------------------------------------------
# Cost Explorer is billed per API request ($0.01/call), unlike everything
# else in this stack -- so it must NOT be called from the page-view path.
# cost_poller runs on its own EventBridge schedule regardless of traffic;
# cost_summary (what the page actually calls) only ever reads the cache item
# that cost_poller wrote, so viewing the dashboard is always $0 no matter how
# often it's opened. See the "Cost analysis" section of the runbook for why.

module "cost_cache_table" {
  source     = "../../modules/dynamodb-table"
  table_name = "${local.name}-cost-cache"
  tags       = var.tags
}

data "aws_iam_policy_document" "cost_poller" {
  statement {
    actions   = ["ce:GetCostAndUsage"]
    resources = ["*"]
  }
  statement {
    # The Budgets IAM action name doesn't match the API call name -- the
    # DescribeBudgets API requires the "ViewBudget" action.
    actions   = ["budgets:ViewBudget"]
    resources = ["*"]
  }
  statement {
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [module.cost_cache_table.arn]
  }
}

module "lambda_cost_poller" {
  source     = "../../modules/lambda-function"
  name       = "${local.name}-cost-poller"
  source_dir = "${path.module}/lambda-src/cost-poller"
  timeout    = 30
  environment_variables = {
    COST_CACHE_TABLE = module.cost_cache_table.name
  }
  inline_policy_json = data.aws_iam_policy_document.cost_poller.json
  tags               = var.tags
}

# Every 6 hours -- AWS's own billing data doesn't update more often than
# that anyway, so this cadence loses no real freshness. At $0.01/call, this
# is ~$1.20/month regardless of how many Admins view the dashboard.
resource "aws_scheduler_schedule" "cost_poller" {
  name                = "${local.name}-cost-poller"
  schedule_expression = "rate(6 hours)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = module.lambda_cost_poller.arn
    role_arn = aws_iam_role.cost_poller_scheduler.arn
  }
}

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cost_poller_scheduler" {
  name               = "${local.name}-cost-poller-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "cost_poller_scheduler_invoke" {
  name = "${local.name}-cost-poller-scheduler-invoke"
  role = aws_iam_role.cost_poller_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = module.lambda_cost_poller.arn
    }]
  })
}

data "aws_iam_policy_document" "cost_summary" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [module.cost_cache_table.arn]
  }
}

module "lambda_cost_summary" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-cost-summary"
  source_dir            = "${path.module}/lambda-src/cost-summary"
  environment_variables = merge(local.common_env, { COST_CACHE_TABLE = module.cost_cache_table.name })
  inline_policy_json    = data.aws_iam_policy_document.cost_summary.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "work_boards_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:Scan"]
    resources = [module.work_boards_table.arn]
  }
}

module "lambda_work_boards_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-work-boards-list"
  source_dir            = "${path.module}/lambda-src/work-boards-list"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.work_boards_list.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "work_boards_write" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
    resources = [module.work_boards_table.arn]
  }
  statement {
    actions   = ["dynamodb:Query"]
    resources = ["${module.work_tasks_table.arn}/index/*"]
  }
  statement {
    actions   = ["dynamodb:BatchWriteItem", "dynamodb:UpdateItem"]
    resources = [module.work_tasks_table.arn]
  }
}

module "lambda_work_boards_write" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-work-boards-write"
  source_dir            = "${path.module}/lambda-src/work-boards-write"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.work_boards_write.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "work_tasks_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [module.work_boards_table.arn]
  }
  statement {
    actions   = ["dynamodb:Query"]
    resources = ["${module.work_tasks_table.arn}/index/*"]
  }
}

module "lambda_work_tasks_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-work-tasks-list"
  source_dir            = "${path.module}/lambda-src/work-tasks-list"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.work_tasks_list.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "work_tasks_write" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [module.work_boards_table.arn]
  }
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
    resources = [module.work_tasks_table.arn]
  }
}

module "lambda_work_tasks_write" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-work-tasks-write"
  source_dir            = "${path.module}/lambda-src/work-tasks-write"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.work_tasks_write.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "attendance_list" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:Scan", "dynamodb:Query"]
    resources = [module.attendance_table.arn, "${module.attendance_table.arn}/index/*"]
  }
}

module "lambda_attendance_list" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-attendance-list"
  source_dir            = "${path.module}/lambda-src/attendance-list"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.attendance_list.json
  tags                  = var.tags
}

data "aws_iam_policy_document" "attendance_write" {
  source_policy_documents = [data.aws_iam_policy_document.read_caller_access.json]
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [module.attendance_table.arn]
  }
}

module "lambda_attendance_write" {
  source                = "../../modules/lambda-function"
  name                  = "${local.name}-attendance-write"
  source_dir            = "${path.module}/lambda-src/attendance-write"
  environment_variables = local.common_env
  inline_policy_json    = data.aws_iam_policy_document.attendance_write.json
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
    { route_key = "PATCH /expenses/{id}", lambda_invoke_arn = module.lambda_expenses_write.invoke_arn, lambda_function_name = module.lambda_expenses_write.name },
    { route_key = "POST /expenses/document-url", lambda_invoke_arn = module.lambda_expenses_document_presign.invoke_arn, lambda_function_name = module.lambda_expenses_document_presign.name },
    { route_key = "GET /employees", lambda_invoke_arn = module.lambda_employees_list.invoke_arn, lambda_function_name = module.lambda_employees_list.name },
    { route_key = "DELETE /employees/{id}", lambda_invoke_arn = module.lambda_employees_write.invoke_arn, lambda_function_name = module.lambda_employees_write.name },
    { route_key = "PATCH /employees/{id}", lambda_invoke_arn = module.lambda_employees_write.invoke_arn, lambda_function_name = module.lambda_employees_write.name },
    { route_key = "POST /admin/users", lambda_invoke_arn = module.lambda_admin_create_user.invoke_arn, lambda_function_name = module.lambda_admin_create_user.name },
    { route_key = "POST /admin/reset-password", lambda_invoke_arn = module.lambda_admin_reset_password.invoke_arn, lambda_function_name = module.lambda_admin_reset_password.name },
    { route_key = "GET /me", lambda_invoke_arn = module.lambda_me.invoke_arn, lambda_function_name = module.lambda_me.name },
    { route_key = "GET /work-boards", lambda_invoke_arn = module.lambda_work_boards_list.invoke_arn, lambda_function_name = module.lambda_work_boards_list.name },
    { route_key = "POST /work-boards", lambda_invoke_arn = module.lambda_work_boards_write.invoke_arn, lambda_function_name = module.lambda_work_boards_write.name },
    { route_key = "PATCH /work-boards/{id}", lambda_invoke_arn = module.lambda_work_boards_write.invoke_arn, lambda_function_name = module.lambda_work_boards_write.name },
    { route_key = "DELETE /work-boards/{id}", lambda_invoke_arn = module.lambda_work_boards_write.invoke_arn, lambda_function_name = module.lambda_work_boards_write.name },
    { route_key = "GET /work-boards/{boardId}/tasks", lambda_invoke_arn = module.lambda_work_tasks_list.invoke_arn, lambda_function_name = module.lambda_work_tasks_list.name },
    { route_key = "POST /work-boards/{boardId}/tasks", lambda_invoke_arn = module.lambda_work_tasks_write.invoke_arn, lambda_function_name = module.lambda_work_tasks_write.name },
    { route_key = "PATCH /work-tasks/{id}", lambda_invoke_arn = module.lambda_work_tasks_write.invoke_arn, lambda_function_name = module.lambda_work_tasks_write.name },
    { route_key = "DELETE /work-tasks/{id}", lambda_invoke_arn = module.lambda_work_tasks_write.invoke_arn, lambda_function_name = module.lambda_work_tasks_write.name },
    { route_key = "GET /attendance", lambda_invoke_arn = module.lambda_attendance_list.invoke_arn, lambda_function_name = module.lambda_attendance_list.name },
    { route_key = "POST /attendance", lambda_invoke_arn = module.lambda_attendance_write.invoke_arn, lambda_function_name = module.lambda_attendance_write.name },
    { route_key = "GET /resumes", lambda_invoke_arn = module.lambda_resumes_list.invoke_arn, lambda_function_name = module.lambda_resumes_list.name },
    { route_key = "GET /resumes/{id}/resume-url", lambda_invoke_arn = module.lambda_resumes_resume_url.invoke_arn, lambda_function_name = module.lambda_resumes_resume_url.name },
    { route_key = "PATCH /resumes/{id}", lambda_invoke_arn = module.lambda_resumes_write.invoke_arn, lambda_function_name = module.lambda_resumes_write.name },
    { route_key = "DELETE /resumes/{id}", lambda_invoke_arn = module.lambda_resumes_write.invoke_arn, lambda_function_name = module.lambda_resumes_write.name },
  ]
}

# Kept as standalone resources (not in the `routes` list above) so that
# adding/changing this one route doesn't pull every other routed Lambda's
# `invoke_arn` into the same for_each dependency graph -- the http_api
# module's `functions_by_name` local is built from the *entire* routes list,
# so any edit to it forces Terraform to re-evaluate (and offer to "fix" drift
# on) every Lambda referenced there, not just the one actually changing.
resource "aws_apigatewayv2_integration" "cloud_resources_list" {
  api_id                 = module.http_api.api_id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda_cloud_resources_list.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "cloud_resources_list" {
  api_id             = module.http_api.api_id
  route_key          = "GET /cloud-resources"
  target             = "integrations/${aws_apigatewayv2_integration.cloud_resources_list.id}"
  authorization_type = "JWT"
  authorizer_id      = module.http_api.authorizer_id
}

resource "aws_lambda_permission" "cloud_resources_list" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_cloud_resources_list.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.http_api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "cost_summary" {
  api_id                 = module.http_api.api_id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda_cost_summary.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "cost_summary" {
  api_id             = module.http_api.api_id
  route_key          = "GET /cost-summary"
  target             = "integrations/${aws_apigatewayv2_integration.cost_summary.id}"
  authorization_type = "JWT"
  authorizer_id      = module.http_api.authorizer_id
}

resource "aws_lambda_permission" "cost_summary" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_cost_summary.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.http_api.execution_arn}/*/*"
}

# --- Billing -----------------------------------------------------------
# Account-wide (not scoped to this stack's resources specifically) -- AWS
# Budgets has no resource-level ARNs to filter by, and total account spend
# is what actually matters for a "did something run away" alert.

resource "aws_budgets_budget" "daily_cost_alert" {
  name         = "${var.project}-daily-cost-alert"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "DAILY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["info@sloudsolutions.com"]
  }
}
