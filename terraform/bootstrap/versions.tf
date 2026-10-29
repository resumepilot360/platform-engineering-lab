terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }
  # Local state on first apply (the bucket does not exist yet). Afterwards:
  # add a backend "s3" block like environments/dev and run `terraform init -migrate-state`.
}
