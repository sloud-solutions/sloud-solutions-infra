output "arn" {
  description = "ARN of the issued certificate; null until validation has been waited on."
  value       = one(aws_acm_certificate_validation.this[*].certificate_arn)
}

output "validation_records" {
  description = "CNAME records to create at an external DNS provider to validate the certificate."
  value = distinct([
    for dvo in aws_acm_certificate.this.domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ])
}
