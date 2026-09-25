locals {
  record_sets = {
    for pair in setproduct(var.names, ["A", "AAAA"]) :
    "${pair[0]}-${pair[1]}" => { name = pair[0], type = pair[1] }
  }
}

resource "aws_route53_record" "alias" {
  for_each = local.record_sets

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = var.cloudfront_domain_name
    zone_id                = var.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}
