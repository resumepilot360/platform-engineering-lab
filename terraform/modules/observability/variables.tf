variable "name" {
  type = string
}

variable "kms_key_arn" {
  description = "KMS key for the SNS topic (must allow events.amazonaws.com and sns)."
  type        = string
}

variable "breakglass_role_arn" {
  type = string
}

variable "expected_secret_reader_arns" {
  description = "Role ARNs expected to read secrets (ESO roles); any other reader alerts."
  type        = list(string)
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
