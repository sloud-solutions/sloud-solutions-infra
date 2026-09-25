provider "aws" {
  region = var.aws.region

  default_tags {
    tags = var.tags
  }
}
