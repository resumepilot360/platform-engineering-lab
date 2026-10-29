variable "project" {
  type    = string
  default = "platform-lab"
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "dev, staging or prod."
  }
}

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  type = bool
}

variable "interface_endpoints" {
  type    = list(string)
  default = []
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "api_public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t4g.medium"]
}

variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"
}

variable "node_min" {
  type    = number
  default = 1
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 4
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "kms_admin_arns" {
  description = "Key administrators (typically the tf-apply role)."
  type        = list(string)
  default     = []
}

variable "persona_trusted_principal_arns" {
  type = list(string)
}

variable "breakglass_principal_arns" {
  type = list(string)
}

variable "terraform_apply_role_arn" {
  type    = string
  default = null
}

variable "permissions_boundary" {
  type    = string
  default = null
}

variable "ecr_repositories" {
  type    = list(string)
  default = ["demo-backend", "demo-frontend"]
}

variable "ecr_pull_through_cache" {
  type = map(object({
    upstream       = string
    credential_arn = optional(string)
  }))
  default = {}
}

variable "secret_names" {
  type    = list(string)
  default = ["demo/backend"]
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
