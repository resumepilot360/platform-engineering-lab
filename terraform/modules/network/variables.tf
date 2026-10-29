variable "name" {
  type = string
}

variable "cidr" {
  description = "VPC CIDR; must be a /16 for the subnet layout."
  type        = string
  validation {
    condition     = can(cidrhost(var.cidr, 0)) && endswith(var.cidr, "/16")
    error_message = "cidr must be a valid /16."
  }
}

variable "az_count" {
  type    = number
  default = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Use 2 or 3 AZs."
  }
}

variable "single_nat_gateway" {
  description = "true: one NAT for all AZs (cheaper, dev). false: one per AZ (no cross-AZ egress dependency)."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Interface endpoint service suffixes, e.g. [\"ecr.api\", \"ecr.dkr\", \"sts\"]."
  type        = list(string)
  default     = []
}

variable "logs_kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "iam_path" {
  type    = string
  default = "/platform-lab/"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "permissions_boundary" {
  description = "Permissions boundary ARN attached to every IAM role this module creates (required by tf-apply)."
  type        = string
  default     = null
}
