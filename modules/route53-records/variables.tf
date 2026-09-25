variable "zone_id" {
  type = string
}

variable "names" {
  description = "Record names (apex and/or www) to alias to CloudFront."
  type        = list(string)
}

variable "cloudfront_domain_name" {
  type = string
}

variable "cloudfront_hosted_zone_id" {
  type = string
}
