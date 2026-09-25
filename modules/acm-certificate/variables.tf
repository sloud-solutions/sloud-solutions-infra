variable "domain_name" {
  type = string
}

variable "subject_alternative_names" {
  type    = list(string)
  default = []
}

variable "zone_id" {
  description = "Route 53 zone used for DNS validation. null when DNS is managed elsewhere."
  type        = string
  default     = null
}

variable "wait_for_validation" {
  description = "With external DNS: block until ACM has issued the certificate."
  type        = bool
  default     = false
}
