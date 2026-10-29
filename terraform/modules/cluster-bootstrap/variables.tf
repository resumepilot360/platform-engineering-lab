variable "cluster_name" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "gitops_repo_url" {
  type = string
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "gitops_path" {
  description = "Path of the app-of-apps for this environment."
  type        = string
}

variable "lbc_chart_version" {
  type    = string
  default = "3.6.2"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.11.6"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.7"
}

variable "iam_path" {
  type    = string
  default = "/platform-lab/"
}

variable "permissions_boundary" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
