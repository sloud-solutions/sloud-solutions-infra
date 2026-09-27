# Username = email. No self-service sign-up: the handful of real users are created
# by an Admin (via the admin-create-user Lambda, or by hand for the first Admin).
resource "aws_cognito_user_pool" "this" {
  name = var.name

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = var.mfa_configuration

  password_policy {
    minimum_length    = var.password_minimum_length
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # Cognito's own built-in email sender (no SES setup needed) delivers the
  # temporary-password invite when an Admin creates a new user.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = var.tags
}

# Public client (no secret) — this is a static single-page app, a client secret
# shipped in the JS bundle can't be kept safe anyway.
resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  explicit_auth_flows = var.explicit_auth_flows

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.access_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# The two roles: Admin (full access, can create users) and Employee (access
# governed by the per-employee "access" list stored in DynamoDB).
resource "aws_cognito_user_group" "admin" {
  name         = "Admin"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Full access; can create/manage other users."
}

resource "aws_cognito_user_group" "employee" {
  name         = "Employee"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Access limited to the pages granted on their employee record."
}
