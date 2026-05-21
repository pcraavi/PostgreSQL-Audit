#!/bin/bash
# deploy-dashboard.sh
# Creates the CloudWatch dashboard with:
#   Widget 1: Log Insights table showing filtered user DML records (real-time)
#   Widget 2: Alarm status widget
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export AWS_REGION=us-east-1
#   export ACCOUNT_ID=123456789012
#   export CLUSTER_NAME=your-aurora-cluster
#   ./deploy-dashboard.sh

set -e

LOG_GROUP="/aws/rds/cluster/${CLUSTER_NAME}/postgresql"
DASHBOARD_NAME="RDS_User_Audit_Activity"

DASHBOARD_BODY=$(cat << EOF
{
  "widgets": [
    {
      "type": "log",
      "x": 0, "y": 0,
      "width": 24, "height": 11,
      "properties": {
        "title": "User DML Audit Records (Live)",
        "queryLanguage": "CWLI",
        "query": "SOURCE '${LOG_GROUP}' | fields @timestamp, @message, @logStream | filter @message like /AUDIT:/ | filter (@message like /SELECT/ or @message like /INSERT/ or @message like /UPDATE/ or @message like /DELETE/) | filter @message not like /SELECT version()/ | filter @message not like /pg_shdescription/ | filter @message not like /pg_catalog/ | filter @message not like /information_schema/ | filter @message not like /DBeaver/ | filter @message not like /PostgreSQL JDBC Driver/ | sort @timestamp desc",
        "region": "${AWS_REGION}",
        "view": "table"
      }
    },
    {
      "type": "alarm",
      "x": 0, "y": 11,
      "width": 11, "height": 4,
      "properties": {
        "title": "User DML Detection Alarm Status",
        "alarms": [
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:rds-user-dml-detected"
        ]
      }
    }
  ]
}
EOF
)

echo "Creating CloudWatch dashboard: ${DASHBOARD_NAME}"
aws cloudwatch put-dashboard \
  --dashboard-name "${DASHBOARD_NAME}" \
  --dashboard-body "${DASHBOARD_BODY}"

echo "Dashboard created: ${DASHBOARD_NAME}"
echo "View at: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
