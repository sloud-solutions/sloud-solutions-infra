output "site_url" {
  value = local.use_domain ? "https://${local.domain_name}" : "https://${module.cloudfront.domain_name}"
}

output "bucket_name" {
  value = module.site_bucket.id
}

output "cloudfront_distribution_id" {
  value = module.cloudfront.id
}

output "cloudfront_domain_name" {
  value = module.cloudfront.domain_name
}

output "site_deploy_role_arn" {
  description = "Set as a variable in the website repo."
  value       = module.site_deploy_role.arn
}

output "name_servers" {
  description = "Set these at the domain registrar (empty without a custom domain)."
  value       = local.use_domain ? module.dns_zone[0].name_servers : []
}
