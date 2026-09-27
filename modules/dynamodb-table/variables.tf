variable "table_name" {
  description = "DynamoDB table name."
  type        = string
}

variable "hash_key_name" {
  description = "Partition key attribute name."
  type        = string
  default     = "id"
}

variable "hash_key_type" {
  description = "Partition key attribute type (S, N, or B)."
  type        = string
  default     = "S"
}

variable "point_in_time_recovery" {
  description = "Enable point-in-time recovery."
  type        = bool
  default     = true
}

variable "extra_attributes" {
  description = "Additional attributes referenced by global_secondary_indexes (the hash key is declared automatically)."
  type        = list(object({ name = string, type = string }))
  default     = []
}

variable "global_secondary_indexes" {
  description = "Optional GSIs, e.g. to look up an item by an attribute other than the primary key."
  type = list(object({
    name            = string
    hash_key        = string
    projection_type = optional(string, "ALL")
  }))
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
