# Non-sensitive identifiers only. Set these as GitHub repository variables
# (not secrets) when the AWS phase is approved.
output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  value = module.state_key.arn
}

output "permissions_boundary_arn" {
  value = module.github_oidc.permissions_boundary_arn
}

output "github_role_arns" {
  value = {
    ci_ecr_push = module.github_oidc.ci_ecr_push_role_arn
    tf_plan     = module.github_oidc.tf_plan_role_arn
    tf_apply    = module.github_oidc.tf_apply_role_arn
  }
}
