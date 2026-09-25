output "zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "Set these at the domain registrar."
  value       = aws_route53_zone.this.name_servers
}
