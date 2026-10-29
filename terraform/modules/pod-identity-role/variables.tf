variable "name" {
  type = string
}

variable "iam_path" {
  type    = string
  default = "/platform-lab/"
}

variable "managed_policies" {
  type    = list(string)
  default = []
}

variable "inline_policy" {
  description = "Inline policy JSON, or null."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Required with service_account (creates the Pod Identity association)."
  type        = string
  default     = null
}

variable "cluster_arn" {
  description = "If set, restricts the trust to this cluster (aws:SourceArn)."
  type        = string
  default     = null
}

variable "namespace" {
  type    = string
  default = null
}

variable "service_account" {
  description = "ServiceAccount to associate; null = role only (e.g. for an EKS add-on association)."
  type        = string
  default     = null
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
