variable "name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Empty = private endpoint only."
  type        = list(string)
  default     = []
  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not expose the EKS API to 0.0.0.0/0; list specific CIDRs or use the private endpoint."
  }
}

variable "secrets_kms_key_arn" {
  description = "KMS key for Kubernetes Secret envelope encryption."
  type        = string
}

variable "ebs_kms_key_arn" {
  type = string
}

variable "logs_kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "instance_types" {
  type    = list(string)
  default = ["t4g.medium"]
}

variable "capacity_type" {
  type    = string
  default = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "ON_DEMAND or SPOT."
  }
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

variable "node_disk_gib" {
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
