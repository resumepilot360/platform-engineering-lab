# Remote state: S3 with native locking (use_lockfile, Terraform >= 1.11; no
# DynamoDB table). Bucket name comes from the bootstrap stack output; pass it at
# init time so no account-specific value is committed:
#   terraform init -backend-config="bucket=<state_bucket output>"
terraform {
  backend "s3" {
    key          = "platform-lab/staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
