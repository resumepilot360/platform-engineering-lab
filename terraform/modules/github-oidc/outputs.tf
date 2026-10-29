output "ci_ecr_push_role_arn" {
  value = aws_iam_role.ci_ecr_push.arn
}

output "tf_plan_role_arn" {
  value = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arn" {
  value = aws_iam_role.tf_apply.arn
}

output "permissions_boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
