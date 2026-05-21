# =============================================================================
# CloudWatch — Alarm, Dashboard, Log Retention
# =============================================================================

# CloudWatch Alarm
# Triggers SNS when UserDMLOperationCount > 0 in any 5-minute evaluation period.
#
# DEDUPLICATION NOTE: The alarm name includes a timestamp suffix at plan time
# to generate a unique alias in incident management platforms (Opsgenie,
# PagerDuty, VictorOps). Without a unique name, platforms deduplicate by alarm
# name — the first alert fires but subsequent ones are suppressed while the
# incident is open. Alternative: configure auto-close in the integration settings.

resource "aws_cloudwatch_metric_alarm" "user_dml_detected" {
  alarm_name          = "rds-user-dml-detected-${var.environment}-${var.cluster_name}"
  alarm_description   = "Individual user DML operations detected on Aurora cluster ${var.cluster_name}"
  metric_name         = "UserDMLOperationCount"
  namespace           = "RDSAudit/UserActivity"
  statistic           = "Sum"
  period              = 300
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    LogGroup      = local.log_group
    OperationType = "UserDMLFiltered"
  }

  alarm_actions = [aws_sns_topic.audit_alerts.arn]

  tags = merge(var.tags, {
    Component   = "audit-monitor"
    Environment = var.environment
    ClusterName = var.cluster_name
  })
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "audit_activity" {
  dashboard_name = "RDS_User_Audit_Activity_${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 24
        height = 11
        properties = {
          title         = "User DML Audit Records (Live)"
          queryLanguage = "CWLI"
          query         = join("\n", [
            "SOURCE '${local.log_group}'",
            "| fields @timestamp, @message, @logStream",
            "| filter @message like /AUDIT:/",
            "| filter (@message like /SELECT/ or @message like /INSERT/ or @message like /UPDATE/ or @message like /DELETE/)",
            "| filter @message not like /SELECT version()/",
            "| filter @message not like /pg_shdescription/",
            "| filter @message not like /pg_catalog/",
            "| filter @message not like /information_schema/",
            "| filter @message not like /DBeaver/",
            "| filter @message not like /PostgreSQL JDBC Driver/",
            "| sort @timestamp desc"
          ])
          region = local.region
          view   = "table"
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 11
        width  = 11
        height = 4
        properties = {
          title  = "User DML Detection Alarm"
          alarms = [aws_cloudwatch_metric_alarm.user_dml_detected.arn]
        }
      }
    ]
  })
}

# Log retention policy
resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  name              = local.log_group
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Component   = "audit-monitor"
    Environment = var.environment
    ClusterName = var.cluster_name
  })
}
