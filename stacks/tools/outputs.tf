output "site_url" {
  value = local.site_url
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
  description = "Set as a variable in the tools repo (AWS_TOOLS_DEPLOY_ROLE_ARN)."
  value       = module.site_deploy_role.arn
}

output "api_endpoint" {
  description = "Set as PUBLIC_API_BASE_URL in the tools repo."
  value       = module.http_api.api_endpoint
}

output "cognito_user_pool_id" {
  description = "Set as PUBLIC_COGNITO_USER_POOL_ID in the tools repo."
  value       = module.user_pool.user_pool_id
}

output "cognito_client_id" {
  description = "Set as PUBLIC_COGNITO_CLIENT_ID in the tools repo."
  value       = module.user_pool.client_id
}

output "photos_bucket_name" {
  value = module.photos_bucket.id
}

output "photos_cloudfront_domain_name" {
  value = module.photos_cloudfront.domain_name
}

output "seed_lambda_name" {
  description = "Invoke once manually after first deploy: aws lambda invoke --function-name <this> --payload '{}' out.json"
  value       = module.lambda_seed.name
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
