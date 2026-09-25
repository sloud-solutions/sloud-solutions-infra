# Private site bucket: the generic hardened bucket plus a policy that lets only
# the given CloudFront distribution read objects (via OAC).
data "aws_iam_policy_document" "cloudfront_read" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.bucket_name}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [var.cloudfront_distribution_arn]
    }
  }
}

module "bucket" {
  source = "../s3-bucket"

  bucket_name                        = var.bucket_name
  noncurrent_version_expiration_days = 30
  source_policy_documents            = [data.aws_iam_policy_document.cloudfront_read.json]
}
