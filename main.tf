# =============================================================================
# Aurora PostgreSQL User Audit Monitor — Terraform Module
# =============================================================================
# Deploys the full audit monitoring stack:
#   - Lambda function (packaged from ../lambda/lambda_function.py)
#   - IAM execution role with least-privilege permissions
#   - EventBridge rule (5-minute schedule)
#   - SNS topic with HTTPS enforcement, account lock-down, KMS encryption
#   - Customer-managed KMS key (required for CloudWatch Alarms -> SNS)
#   - CloudWatch Alarm on UserDMLOperationCount metric
#   - CloudWatch log retention policy
# =============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  log_group  = "/aws/rds/cluster/${var.cluster_name}/postgresql"
}
