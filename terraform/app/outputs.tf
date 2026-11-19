output "dashboard_url" {
  description = "Open this in a browser - the live uptime dashboard"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard in the AWS console"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "lambda_function_name" {
  value = aws_lambda_function.app.function_name
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.checks.name
}
