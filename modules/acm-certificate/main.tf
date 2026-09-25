# CloudFront only accepts certificates from us-east-1; the caller's provider
# must be configured for that region.
#
# DNS validation is handled one of two ways:
#   - zone_id set:          validation records are created in Route 53.
#   - zone_id null (external DNS, e.g. Cloudflare): the records are exposed via
#     the `validation_records` output to be added by hand. Set
#     wait_for_validation = true once they exist to block until ACM issues it.
locals {
  manage_dns = var.zone_id != null
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    } if local.manage_dns
  }

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.manage_dns || var.wait_for_validation ? 1 : 0

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = local.manage_dns ? [for r in aws_route53_record.validation : r.fqdn] : null
}
