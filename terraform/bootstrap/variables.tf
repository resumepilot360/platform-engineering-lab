variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "platform-lab"
}

variable "github_repository" {
  type    = string
  default = "resumepilot360/platform-engineering-lab"
}

variable "create_github_oidc_provider" {
  description = "false if the account already has the token.actions.githubusercontent.com provider."
  type        = bool
  default     = true
}
