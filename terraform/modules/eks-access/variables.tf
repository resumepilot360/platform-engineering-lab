variable "cluster_name" {
  type = string
}

variable "trusted_principal_arns" {
  description = "Who may assume the persona roles, typically the IAM Identity Center permission-set roles (or the account root while bootstrapping)."
  type        = list(string)
}

variable "breakglass_principal_arns" {
  description = "Small set of principals allowed to assume break-glass (with MFA)."
  type        = list(string)
}

variable "terraform_role_arn" {
  description = "Terraform apply role granted cluster-admin for bootstrap Helm releases; null to skip."
  type        = string
  default     = null
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
