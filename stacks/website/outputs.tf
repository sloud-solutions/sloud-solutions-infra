output "site_url" {
  value = local.attach ? "https://${local.domain_name}" : "https://${module.cloudfront.domain_name}"
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
  description = "Route 53 only: set these at the domain registrar (empty otherwise)."
  value       = local.use_route53 ? module.dns_zone[0].name_servers : []
}

output "acm_validation_records" {
  description = "External DNS: add these CNAMEs (DNS only) so ACM can validate the certificate."
  value       = local.use_domain ? module.certificate[0].validation_records : []
}

output "dns_records_to_add" {
  description = "External DNS: point these names (CNAME, DNS only) at the CloudFront domain."
  value = local.attach && !local.use_route53 ? {
    names  = local.domain_names
    target = module.cloudfront.domain_name
  } : null
}
