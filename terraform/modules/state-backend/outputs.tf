output "bucket_name" {
  description = "State bucket name."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "State bucket ARN."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB lock table name."
  value       = aws_dynamodb_table.lock.name
}
