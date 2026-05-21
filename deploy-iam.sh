#!/bin/bash
# deploy-iam.sh
# Creates the Lambda execution role and attaches required policies.
# Run once per account before deploying the Lambda function.
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=us-east-1
#   ./deploy-iam.sh

set -e

ROLE_NAME="lambda-rds-audit-monitor"
POLICY_NAME="lambda-rds-audit-monitor-policy"

echo "Creating IAM role: ${ROLE_NAME}"
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://lambda-trust-policy.json \
  --description "Execution role for Aurora PostgreSQL audit monitor Lambda"

echo "Creating inline permissions policy"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document file://lambda-permissions-policy.json

echo "Waiting 30 seconds for IAM propagation..."
sleep 30

echo "IAM role ready: ${ROLE_NAME}"
aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text
