variable "name" {
  type = string
}

variable "github_repository" {
  description = "owner/repo, e.g. resumepilot360/platform-engineering-lab."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use owner/repo."
  }
}

variable "apply_environment" {
  description = "GitHub environment whose jobs may assume tf-apply (has required reviewers)."
  type        = string
  default     = "production"
}

variable "create_provider" {
  description = "Create the account-level GitHub OIDC provider (false if it already exists)."
  type        = bool
  default     = true
}

variable "region" {
  type = string
}

variable "ecr_repository_prefix" {
  description = "ci-ecr-push may push only to repositories under this prefix."
  type        = string
}

variable "state_bucket_arn" {
  type = string
}

variable "state_key_prefix" {
  description = "State object prefix this environment's roles may touch, e.g. platform-lab/dev/."
  type        = string
}

variable "state_kms_key_arn" {
  type = string
}

variable "iam_path" {
  type    = string
  default = "/platform-lab/"
}

variable "tags" {
  type    = map(string)
  default = {}
}
