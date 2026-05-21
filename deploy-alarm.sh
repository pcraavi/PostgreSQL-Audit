#!/bin/bash
# deploy-alarm.sh
# Creates the CloudWatch Alarm that evaluates the custom metric published
# by the Lambda function and triggers SNS when user DML is detected.
#
# The alarm name is timestamped at deploy time to generate a unique alias
# in the incident management platform. Without the timestamp, platforms
# like Opsgenie/PagerDuty deduplicate by alarm name — the first alert fires
# correctly but subsequent ones are suppressed while the incident is open.
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=us-east-1
#   export ACCOUNT_ID=123456789012
#   export CLUSTER_NAME=your-aurora-cluster
#   ./deploy-alarm.sh

set -e

ALARM_NAME="rds-user-dml-detected-$(date +%s)"
LOG_GROUP="/aws/rds/cluster/${CLUSTER_NAME}/postgresql"
SNS_ARN="arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:rds-user-audit-alerts"

echo "Creating CloudWatch Alarm: ${ALARM_NAME}"
aws cloudwatch put-metric-alarm \
  --alarm-name "${ALARM_NAME}" \
  --alarm-description "Individual user DML operations detected on Aurora PostgreSQL cluster ${CLUSTER_NAME}" \
  --metric-name "UserDMLOperationCount" \
  --namespace "RDSAudit/UserActivity" \
  --statistic "Sum" \
  --period 300 \
  --threshold 0 \
  --comparison-operator "GreaterThanThreshold" \
  --evaluation-periods 1 \
  --alarm-actions "${SNS_ARN}" \
  --treat-missing-data "notBreaching" \
  --dimensions \
    "Name=LogGroup,Value=${LOG_GROUP}" \
    "Name=OperationType,Value=UserDMLFiltered"

echo ""
echo "Alarm created: ${ALARM_NAME}"
echo ""
echo "NOTE: Alarm will show INSUFFICIENT_DATA until the Lambda publishes"
echo "its first metric data point. Invoke the Lambda manually to initialise:"
echo ""
echo "  aws lambda invoke --function-name rds-user-audit-monitor response.json"
echo "  cat response.json"
