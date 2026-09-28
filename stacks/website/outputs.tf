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

output "apply_api_endpoint" {
  description = "Set as PUBLIC_APPLY_API_BASE_URL in the website repo."
  value       = aws_apigatewayv2_api.apply.api_endpoint
}

output "ses_dkim_records_to_add" {
  description = "Add these 3 CNAME records (DNS only) at your DNS provider so outbound application-notification mail is DKIM-signed and doesn't land in spam."
  value = [
    for token in aws_ses_domain_dkim.notify.dkim_tokens : {
      name  = "${token}._domainkey.${local.domain_name}"
      type  = "CNAME"
      value = "${token}.dkim.amazonses.com"
    }
  ]
}

output "ses_domain_verification_record_to_add" {
  description = "Add this TXT record (DNS only) too -- proves domain ownership to SES, separate from the DKIM CNAMEs above."
  value = {
    name  = "_amazonses.${local.domain_name}"
    type  = "TXT"
    value = aws_ses_domain_identity.notify.verification_token
  }
}
