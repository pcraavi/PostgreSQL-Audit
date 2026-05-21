#!/bin/bash
# deploy-lambda.sh
# Packages and deploys (or updates) the Lambda function.
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=us-east-1
#   export ACCOUNT_ID=123456789012
#   export CLUSTER_NAME=your-aurora-cluster
#   ./deploy-lambda.sh

set -e

FUNCTION_NAME="rds-user-audit-monitor"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/lambda-rds-audit-monitor"
LOG_GROUP="/aws/rds/cluster/${CLUSTER_NAME}/postgresql"
ZIP_FILE="audit_monitor.zip"

echo "Packaging Lambda..."
zip -j "${ZIP_FILE}" lambda_function.py

# Check if function already exists
if aws lambda get-function --function-name "${FUNCTION_NAME}" 2>/dev/null; then
  echo "Updating existing Lambda function..."
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --zip-file "fileb://${ZIP_FILE}"

  aws lambda update-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --environment "Variables={LOG_GROUP_NAME=${LOG_GROUP},METRIC_NAMESPACE=RDSAudit/UserActivity,QUERY_WINDOW_MINUTES=5}" \
    --timeout 300
else
  echo "Creating new Lambda function..."
  aws lambda create-function \
    --function-name "${FUNCTION_NAME}" \
    --runtime python3.9 \
    --role "${ROLE_ARN}" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://${ZIP_FILE}" \
    --timeout 300 \
    --description "Aurora PostgreSQL user DML audit monitor" \
    --environment "Variables={LOG_GROUP_NAME=${LOG_GROUP},METRIC_NAMESPACE=RDSAudit/UserActivity,QUERY_WINDOW_MINUTES=5}" \
    --tags "Environment=production,Component=audit-monitor,Owner=engineering"
fi

echo ""
echo "Lambda deployed: ${FUNCTION_NAME}"
echo ""
echo "Test invocation:"
echo "  aws lambda invoke --function-name ${FUNCTION_NAME} --payload '{}' response.json"
echo "  cat response.json"
