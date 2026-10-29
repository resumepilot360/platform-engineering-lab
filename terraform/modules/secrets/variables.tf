variable "environment" {
  type = string
}

variable "secret_names" {
  description = "Names under <environment>/, e.g. [\"demo/backend\"]."
  type        = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "reader_role_arns" {
  description = "Roles allowed to read the secret values (ESO role, break-glass)."
  type        = list(string)
}

variable "recovery_window_in_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
