# CloudFront requires ACM certificates in us-east-1, which is also the project
# region (enforced by config/schema.json), so a single provider is enough.
provider "aws" {
  region = var.aws.region

  default_tags {
    tags = merge(var.tags, { GitSha = var.git_sha })
  }
}
