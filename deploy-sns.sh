#!/bin/bash
# deploy-sns.sh
# Creates the SNS topic, applies the secure resource policy,
# creates and applies the customer-managed KMS key, and adds subscriptions.
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=us-east-1
#   export ACCOUNT_ID=123456789012
#   export INCIDENT_PLATFORM_URL=https://your-platform/endpoint?apiKey=YOUR_KEY
#   export ALERT_EMAIL=engineering-team@your-company.com
#   ./deploy-sns.sh

set -e

TOPIC_NAME="rds-user-audit-alerts"
KMS_ALIAS="alias/rds-audit-sns"

# Replace placeholders in the policy files
sed "s/YOUR_ACCOUNT_ID/${ACCOUNT_ID}/g; s/YOUR_REGION/${AWS_REGION}/g" \
  topic-policy.json > /tmp/topic-policy-resolved.json

sed "s/YOUR_ACCOUNT_ID/${ACCOUNT_ID}/g" \
  kms-key-policy.json > /tmp/kms-key-policy-resolved.json

# 1. Create the SNS topic
echo "Creating SNS topic: ${TOPIC_NAME}"
TOPIC_ARN=$(aws sns create-topic \
  --name "${TOPIC_NAME}" \
  --query 'TopicArn' \
  --output text)
echo "Topic ARN: ${TOPIC_ARN}"

# 2. Create customer-managed KMS key
# NOTE: alias/aws/sns (AWS managed key) CANNOT be used with CloudWatch Alarms.
# CloudWatch needs kms:GenerateDataKey which cannot be granted on managed keys.
echo "Creating KMS key for SNS encryption..."
KMS_KEY_ID=$(aws kms create-key \
  --description "KMS key for RDS audit SNS topic encryption" \
  --key-policy file:///tmp/kms-key-policy-resolved.json \
  --query 'KeyMetadata.KeyId' \
  --output text)
echo "KMS Key ID: ${KMS_KEY_ID}"

aws kms create-alias \
  --alias-name "${KMS_ALIAS}" \
  --target-key-id "${KMS_KEY_ID}"
echo "KMS alias created: ${KMS_ALIAS}"

# 3. Apply resource policy (HTTPS enforcement + account lock-down)
echo "Applying SNS topic resource policy..."
aws sns set-topic-attributes \
  --topic-arn "${TOPIC_ARN}" \
  --attribute-name Policy \
  --attribute-value file:///tmp/topic-policy-resolved.json

# 4. Apply KMS encryption
echo "Applying KMS encryption to SNS topic..."
aws sns set-topic-attributes \
  --topic-arn "${TOPIC_ARN}" \
  --attribute-name KmsMasterKeyId \
  --attribute-value "${KMS_ALIAS}"

# 5. Add subscriptions
echo "Adding incident platform subscription..."
aws sns subscribe \
  --topic-arn "${TOPIC_ARN}" \
  --protocol https \
  --notification-endpoint "${INCIDENT_PLATFORM_URL}"

echo "Adding email subscription..."
aws sns subscribe \
  --topic-arn "${TOPIC_ARN}" \
  --protocol email \
  --notification-endpoint "${ALERT_EMAIL}"

echo ""
echo "SNS topic ready: ${TOPIC_ARN}"
echo "KMS key:         ${KMS_KEY_ID}"
echo "Email subscription requires confirmation — check inbox."
