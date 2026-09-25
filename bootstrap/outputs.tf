output "state_bucket" {
  value = module.state_bucket.id
}

output "plan_role_arn" {
  description = "Set as repo variable AWS_PLAN_ROLE_ARN."
  value       = module.plan_role.arn
}

output "apply_role_arn" {
  description = "Set as repo variable AWS_APPLY_ROLE_ARN."
  value       = module.apply_role.arn
}
