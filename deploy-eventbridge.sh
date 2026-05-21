#!/bin/bash
# deploy-eventbridge.sh
# Creates the EventBridge rule that triggers the Lambda every 5 minutes
# and grants EventBridge permission to invoke the function.
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=us-east-1
#   export ACCOUNT_ID=123456789012
#   ./deploy-eventbridge.sh

set -e

RULE_NAME="rds-audit-monitor-schedule"
FUNCTION_NAME="rds-user-audit-monitor"
FUNCTION_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
RULE_ARN="arn:aws:events:${AWS_REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}"

echo "Creating EventBridge rule: ${RULE_NAME}"
aws events put-rule \
  --name "${RULE_NAME}" \
  --description "Trigger Aurora PostgreSQL audit monitor every 5 minutes" \
  --schedule-expression "rate(5 minutes)" \
  --state ENABLED

echo "Adding Lambda as target..."
aws events put-targets \
  --rule "${RULE_NAME}" \
  --targets "Id=AuditMonitorTarget,Arn=${FUNCTION_ARN}"

echo "Granting EventBridge permission to invoke Lambda..."
aws lambda add-permission \
  --function-name "${FUNCTION_NAME}" \
  --statement-id "allow-eventbridge-audit-monitor" \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "${RULE_ARN}"

echo ""
echo "EventBridge schedule active: ${RULE_NAME}"
echo "Lambda will be invoked every 5 minutes."
