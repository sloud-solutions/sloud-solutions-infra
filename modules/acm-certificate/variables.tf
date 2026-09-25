variable "domain_name" {
  type = string
}

variable "subject_alternative_names" {
  type    = list(string)
  default = []
}

variable "zone_id" {
  description = "Route 53 zone used for DNS validation."
  type        = string
}
