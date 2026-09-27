output "arn" {
  value = aws_lambda_function.this.arn
}

output "invoke_arn" {
  value = aws_lambda_function.this.invoke_arn
}

output "name" {
  value = aws_lambda_function.this.function_name
}

output "role_arn" {
  value = aws_iam_role.exec.arn
}
