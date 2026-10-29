output "persona_role_arns" {
  value = { for k, r in aws_iam_role.persona : k => r.arn }
}

output "breakglass_role_arn" {
  value = aws_iam_role.breakglass.arn
}
