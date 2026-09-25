variable "bucket_name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "cloudfront_distribution_arn" {
  description = "ARN of the distribution allowed to read from the bucket."
  type        = string
}
