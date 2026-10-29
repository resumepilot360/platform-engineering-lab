variable "alias" {
  description = "Alias without the alias/ prefix, e.g. platform-lab-dev-secrets."
  type        = string
}

variable "description" {
  type = string
}

variable "admin_principal_arns" {
  description = "Principals allowed to administer (not use) the key, e.g. the Terraform apply role."
  type        = list(string)
  default     = []
}

variable "user_principal_arns" {
  description = "Principals allowed to encrypt/decrypt with the key."
  type        = list(string)
  default     = []
}

variable "via_services" {
  description = "If set, key users may use the key only through these services (kms:ViaService), e.g. secretsmanager.us-east-1.amazonaws.com."
  type        = list(string)
  default     = []
}

variable "service_principals" {
  description = "AWS service principals that may use the key directly, e.g. logs.us-east-1.amazonaws.com."
  type        = list(string)
  default     = []
}

variable "deletion_window_in_days" {
  description = "Pending-deletion window. Deletion is irreversible after it ends."
  type        = number
  default     = 30
  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "Must be between 7 and 30 days."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "allow_grants" {
  description = "Allow key users to create grants for AWS resources (needed for EBS/Auto Scaling)."
  type        = bool
  default     = false
}
