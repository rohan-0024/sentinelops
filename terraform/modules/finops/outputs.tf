output "lambda_name" {
  description = "Autopilot Lambda function name."
  value       = aws_lambda_function.autopilot.function_name
}

output "override_parameter" {
  description = "SSM parameter to set to keep-alive to skip teardown."
  value       = aws_ssm_parameter.override.name
}

output "dlq_url" {
  description = "Dead-letter queue URL."
  value       = aws_sqs_queue.dlq.url
}
