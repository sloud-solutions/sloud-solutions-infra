# Intentionally empty: bucket/key/region are supplied at init time from the
# rendered config (`terraform init -backend-config=../../.rendered/backend.hcl`).
terraform {
  backend "s3" {}
}
