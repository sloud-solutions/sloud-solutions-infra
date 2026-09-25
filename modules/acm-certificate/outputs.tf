output "arn" {
  description = "Certificate ARN, available only once validation has completed."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
