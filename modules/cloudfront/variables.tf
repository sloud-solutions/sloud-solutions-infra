variable "name" {
  description = "Name prefix for the distribution, OAC and function."
  type        = string
}

variable "bucket_regional_domain_name" {
  description = "Regional domain name of the origin S3 bucket."
  type        = string
}

variable "aliases" {
  description = "Custom domain names (CNAMEs). Empty to use the *.cloudfront.net domain."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "us-east-1 ACM certificate ARN. Required when aliases is non-empty."
  type        = string
  default     = null
}

variable "price_class" {
  type    = string
  default = "PriceClass_100"
}

variable "default_root_object" {
  type    = string
  default = "index.html"
}
