variable "aws_account_id" {
  description = "The only account this configuration may run against (provider allowed_account_ids)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "12-digit AWS account ID."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  description = "dev: one NAT (cost). staging: one per AZ (availability)."
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = "dev routes AWS API traffic via NAT to save ~$44/month; staging keeps it private."
  type        = list(string)
  default     = []
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "api_public_access_cidrs" {
  description = "Your egress IP(s) as /32 for kubectl over the public endpoint; [] = private only."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t4g.medium"]
}

variable "node_capacity_type" {
  type    = string
  default = "SPOT"
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
  default = 3
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "persona_trusted_principal_arns" {
  description = "Identity Center permission-set role ARNs allowed to assume the EKS persona roles."
  type        = list(string)
}

variable "breakglass_principal_arns" {
  description = "Principals allowed to assume break-glass (MFA enforced by the role)."
  type        = list(string)
}

variable "terraform_apply_role_arn" {
  description = "bootstrap output github_role_arns.tf_apply"
  type        = string
  default     = null
}

variable "permissions_boundary" {
  description = "bootstrap output permissions_boundary_arn"
  type        = string
  default     = null
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "enable_cluster_bootstrap" {
  description = "Stage 2: install LBC + Argo CD + root app. Apply once with false, then true."
  type        = bool
  default     = false
}

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/resumepilot360/platform-engineering-lab.git"
}

variable "gitops_path" {
  description = "App-of-apps path for this cluster (AWS overlay: ECR images, ALB ingress)."
  type        = string
  default     = "gitops/clusters/aws-dev"
}
