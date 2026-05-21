output "lambda_function_name" {
  description = "Name of the audit monitor Lambda function"
  value       = aws_lambda_function.audit_monitor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the audit monitor Lambda function"
  value       = aws_lambda_function.audit_monitor.arn
}

output "sns_topic_arn" {
  description = "ARN of the audit alerts SNS topic"
  value       = aws_sns_topic.audit_alerts.arn
}

output "kms_key_id" {
  description = "ID of the customer-managed KMS key for SNS encryption"
  value       = aws_kms_key.sns_encryption.key_id
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key"
  value       = aws_kms_key.sns_encryption.arn
}

output "cloudwatch_alarm_name" {
  description = "Name of the CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.user_dml_detected.alarm_name
}

output "cloudwatch_alarm_arn" {
  description = "ARN of the CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.user_dml_detected.arn
}

output "dashboard_url" {
  description = "URL to the CloudWatch dashboard"
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.audit_activity.dashboard_name}"
}

output "log_group" {
  description = "CloudWatch log group for Aurora PostgreSQL audit logs"
  value       = local.log_group
}
