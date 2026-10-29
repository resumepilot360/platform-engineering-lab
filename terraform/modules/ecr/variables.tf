variable "prefix" {
  description = "Repository namespace, e.g. platform-lab."
  type        = string
}

variable "repositories" {
  type = list(string)
}

variable "kms_key_arn" {
  type = string
}

variable "keep_images" {
  type    = number
  default = 50
}

variable "pull_through_cache" {
  description = "Map of ECR prefix => { upstream, credential_arn (null for anonymous upstreams) }."
  type = map(object({
    upstream       = string
    credential_arn = optional(string)
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
