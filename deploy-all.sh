#!/bin/bash
# deploy-all.sh
# Full CLI deployment sequence — runs all steps in order.
# Use this for a first-time manual deployment to a single account.
# For multi-account deployment, use the Terraform module instead.
#
# Usage:
#   export AWS_PROFILE=your-aws-profile
#   export AWS_REGION=us-east-1
#   export ACCOUNT_ID=123456789012
#   export CLUSTER_NAME=your-aurora-cluster
#   export ALERT_EMAIL=engineering-team@your-company.com
#   export INCIDENT_PLATFORM_URL=https://your-platform/endpoint?apiKey=YOUR_KEY
#   export RETENTION_DAYS=365
#   chmod +x deploy-all.sh
#   ./deploy-all.sh

set -e

echo "========================================"
echo "Aurora PostgreSQL User Audit Monitor"
echo "Full deployment: ${CLUSTER_NAME} in ${AWS_REGION}"
echo "========================================"
echo ""

# Validate required vars
for VAR in AWS_REGION ACCOUNT_ID CLUSTER_NAME ALERT_EMAIL INCIDENT_PLATFORM_URL; do
  if [ -z "${!VAR}" ]; then
    echo "ERROR: ${VAR} is not set"
    exit 1
  fi
done

# Step 1 — IAM
echo "[1/6] Deploying IAM role..."
cd iam && ./deploy-iam.sh && cd ..

# Step 2 — Lambda
echo "[2/6] Deploying Lambda function..."
cd lambda && ./deploy-lambda.sh && cd ..

# Step 3 — EventBridge
echo "[3/6] Deploying EventBridge schedule..."
cd eventbridge && ./deploy-eventbridge.sh && cd ..

# Step 4 — SNS
echo "[4/6] Deploying SNS topic..."
cd sns && ./deploy-sns.sh && cd ..

# Step 5 — CloudWatch Alarm
echo "[5/6] Deploying CloudWatch alarm..."
cd cloudwatch && ./deploy-alarm.sh && cd ..

# Step 6 — CloudWatch Dashboard + Log Retention
echo "[6/6] Deploying dashboard and log retention..."
cd cloudwatch
./deploy-dashboard.sh
./set-log-retention.sh
cd ..

echo ""
echo "========================================"
echo "Deployment complete."
echo ""
echo "Next steps:"
echo "  1. Confirm email subscription (check ${ALERT_EMAIL} inbox)"
echo "  2. Test Lambda: aws lambda invoke --function-name rds-user-audit-monitor --payload '{}' response.json"
echo "  3. Run pgaudit-setup.sql against the Aurora cluster to enable per-user logging"
echo "  4. Check CloudWatch dashboard: RDS_User_Audit_Activity"
echo "========================================"
