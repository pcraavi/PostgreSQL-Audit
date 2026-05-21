# =============================================================================
# SNS Topic — Secure Configuration
#
# Three security layers:
#   1. DenyInsecureTransport  — enforces HTTPS delivery
#   2. LimitToAccountOnly     — blocks cross-account confused deputy attacks
#   3. Customer-managed KMS   — encryption at rest
#
# KMS NOTE: alias/aws/sns (AWS managed key) CANNOT be used with CloudWatch Alarms.
# AWS managed key policies are immutable — CloudWatch cannot be granted
# kms:GenerateDataKey. A customer-managed key with an explicit CloudWatch
# service grant is required. The managed key works when Lambda publishes
# directly to SNS; the restriction is specific to CloudWatch Alarms -> SNS.
# =============================================================================

# Customer-managed KMS key
resource "aws_kms_key" "sns_encryption" {
  description             = "KMS key for RDS audit SNS topic encryption (${var.environment})"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountManagement"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # CloudWatch Alarms MUST be granted this explicitly
        # This is the fix for: "CloudWatch Alarms does not have authorization
        # to access the SNS topic encryption key"
        Sid       = "AllowCloudWatchAlarmsToUseKey"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Component   = "audit-monitor"
    Environment = var.environment
  })
}

resource "aws_kms_alias" "sns_encryption" {
  name          = "alias/rds-audit-sns-${var.environment}"
  target_key_id = aws_kms_key.sns_encryption.key_id
}

# SNS topic with encryption
resource "aws_sns_topic" "audit_alerts" {
  name              = "rds-user-audit-alerts-${var.environment}"
  kms_master_key_id = aws_kms_key.sns_encryption.arn
  display_name      = "RDS User Audit Alerts"

  tags = merge(var.tags, {
    Component   = "audit-monitor"
    Environment = var.environment
    ClusterName = var.cluster_name
  })
}

# SNS resource policy: HTTPS enforcement + CloudWatch + account lock-down
resource "aws_sns_topic_policy" "audit_alerts" {
  arn = aws_sns_topic.audit_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.audit_alerts.arn
        Condition = {
          ArnLike      = { "aws:SourceArn" = "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:*" }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.audit_alerts.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "LimitToAccountOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.audit_alerts.arn
        Condition = { StringNotEquals = { "aws:SourceAccount" = local.account_id } }
      }
    ]
  })
}

# Incident platform subscription (Opsgenie, PagerDuty, VictorOps, etc.)
resource "aws_sns_topic_subscription" "incident_platform" {
  topic_arn = aws_sns_topic.audit_alerts.arn
  protocol  = "https"
  endpoint  = var.incident_platform_url
}

# Email subscription
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.audit_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
