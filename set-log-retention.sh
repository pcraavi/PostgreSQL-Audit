#!/bin/bash
# set-log-retention.sh
# Sets CloudWatch log retention policy for the Aurora PostgreSQL log group.
# Default is indefinite retention — set this explicitly to control cost
# and meet your compliance window requirement.
#
# Common retention values (days):
#   90    - 3 months minimum
#   365   - 1 year
#   2557  - 7 years (common for regulated industries)
#
# Usage:
#   export AWS_PROFILE=your-profile
#   export CLUSTER_NAME=your-aurora-cluster
#   export RETENTION_DAYS=365
#   ./set-log-retention.sh

set -e

LOG_GROUP="/aws/rds/cluster/${CLUSTER_NAME}/postgresql"
RETENTION_DAYS="${RETENTION_DAYS:-365}"

echo "Setting log retention: ${LOG_GROUP} -> ${RETENTION_DAYS} days"
aws logs put-retention-policy \
  --log-group-name "${LOG_GROUP}" \
  --retention-in-days "${RETENTION_DAYS}"

echo "Retention policy applied."
