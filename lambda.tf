# =============================================================================
# Lambda Function — Audit Monitor
# =============================================================================

# Package the Lambda function from source
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/dist/audit_monitor.zip"
}

# IAM role for Lambda execution
resource "aws_iam_role" "lambda_exec" {
  name               = "lambda-rds-audit-monitor-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Component = "audit-monitor" })
}

# Least-privilege inline policy
resource "aws_iam_role_policy" "lambda_permissions" {
  name = "rds-audit-monitor-permissions"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsInsightsRead"
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:GetQueryResults",
          "logs:StopQuery",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchMetricsWrite"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid    = "LambdaBasicExecution"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "audit_monitor" {
  function_name    = "rds-user-audit-monitor-${var.environment}"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_exec.arn
  timeout          = 300   # Log Insights queries can be slow on large log groups
  description      = "Aurora PostgreSQL individual-user DML audit monitor"

  environment {
    variables = {
      LOG_GROUP_NAME       = local.log_group
      METRIC_NAMESPACE     = "RDSAudit/UserActivity"
      QUERY_WINDOW_MINUTES = tostring(var.query_window_minutes)
    }
  }

  tags = merge(var.tags, {
    Component   = "audit-monitor"
    Environment = var.environment
    ClusterName = var.cluster_name
  })
}

# EventBridge permission to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "allow-eventbridge-audit-monitor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.audit_schedule.arn
}

# EventBridge rule — 5-minute schedule
resource "aws_cloudwatch_event_rule" "audit_schedule" {
  name                = "rds-audit-monitor-schedule-${var.environment}"
  description         = "Trigger Aurora PostgreSQL user audit monitor every 5 minutes"
  schedule_expression = "rate(${var.query_window_minutes} minutes)"
  tags                = merge(var.tags, { Component = "audit-monitor" })
}

resource "aws_cloudwatch_event_target" "audit_monitor" {
  rule      = aws_cloudwatch_event_rule.audit_schedule.name
  target_id = "AuditMonitorLambda"
  arn       = aws_lambda_function.audit_monitor.arn
}
