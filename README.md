# Aurora PostgreSQL User Audit Monitor

Detect and alert on individual user DML activity on Aurora PostgreSQL clusters using pgAudit, Lambda, CloudWatch, and SNS.

**Audit scope:** Individual human users making direct DML changes (SELECT, INSERT, UPDATE, DELETE) on application tables. Application service accounts are deliberately excluded — their DML is expected. The risk surface is direct human access: a developer connected via psql, a support engineer running an ad-hoc update, a credential that should never have had direct database access.

---

## Repository Structure

```
├── README.md
├── deploy-all.sh                        # Full CLI deployment sequence (single account)
│
├── lambda/
│   ├── lambda_function.py               # Core audit monitor — Log Insights query, metric publish
│   └── deploy-lambda.sh                 # Package and deploy / update Lambda
│
├── iam/
│   ├── lambda-trust-policy.json         # Lambda execution role trust policy
│   ├── lambda-permissions-policy.json   # Least-privilege: Log Insights read + CW metric write
│   └── deploy-iam.sh                    # Create role and attach inline policy
│
├── eventbridge/
│   └── deploy-eventbridge.sh            # 5-minute schedule rule + Lambda target + invoke permission
│
├── sns/
│   ├── topic-policy.json                # Resource policy: AllowCW + DenyHTTP + LimitToAccount
│   ├── kms-key-policy.json              # Customer-managed key with CloudWatch service grant
│   └── deploy-sns.sh                    # Create topic, KMS key, apply policies, add subscriptions
│
├── cloudwatch/
│   ├── log-insights-query.txt           # Standalone filter query for manual console use
│   ├── deploy-alarm.sh                  # CloudWatch alarm on UserDMLOperationCount metric
│   ├── deploy-dashboard.sh              # Two-widget dashboard: live audit table + alarm status
│   └── set-log-retention.sh             # Set log retention policy (default 365 days)
│
├── sql/
│   └── pgaudit-setup.sql                # pgAudit install, per-user enable, verification queries
│
└── terraform/                           # Full IaC module — deploys the complete stack
    ├── main.tf                          # Providers, data sources, locals
    ├── variables.tf                     # All inputs with descriptions and defaults
    ├── lambda.tf                        # Lambda function + IAM role + EventBridge rule
    ├── sns.tf                           # KMS key + SNS topic + resource policy + subscriptions
    ├── cloudwatch.tf                    # Alarm + dashboard + log retention
    ├── outputs.tf                       # ARNs and URLs for all created resources
    └── terraform.tfvars.example         # Copy to terraform.tfvars and fill in before deploying
```

---

## Architecture

```
Aurora PostgreSQL  (pgAudit per-user logging)
        │  pgAudit → PostgreSQL log stream
        ▼
CloudWatch Logs   /aws/rds/cluster/<cluster>/postgresql
        │
        ├──► CloudWatch Dashboard  (real-time Log Insights table view)
        │
EventBridge  rate(5 minutes)
        │
        ▼
lambda/lambda_function.py
  ├── Runs AUDIT_FILTER_QUERY against last 5-minute window
  ├── Excludes system catalog queries and tool noise
  ├── Counts user DML: SELECT / INSERT / UPDATE / DELETE
  └── Publishes UserDMLOperationCount → RDSAudit/UserActivity
        │
        ▼
CloudWatch Custom Metric  UserDMLOperationCount
        │
        ▼
CloudWatch Alarm  threshold: count > 0
        │
        ▼
SNS Topic  rds-user-audit-alerts
  ├── HTTPS → incident platform (Opsgenie / PagerDuty / VictorOps)
  └── Email → engineering team
```

**Why Lambda between Log Insights and the alarm:**
CloudWatch Alarms cannot evaluate Log Insights query results directly — there is no native integration. Lambda bridges the gap: it runs the query, extracts the count, and publishes it as a standard CloudWatch metric the alarm can evaluate.

Lambda execution logs also provide a timestamped, independent record of every detection event — separate from and corroborating the raw pgAudit stream. Relevant when compliance asks "when was this first detected and by what mechanism?"

---

## Prerequisites

- Aurora PostgreSQL cluster with parameter group edit access
- AWS CLI configured (`AWS_PROFILE`, `AWS_REGION`)
- Python 3.9 (Lambda runtime)
- Incident management platform with HTTPS webhook support

---

## Option 1: Terraform (recommended for multiple accounts)

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

**Required variables** (see `terraform/variables.tf` for full list and defaults):

| Variable | Description |
|---|---|
| `cluster_name` | Aurora cluster name — used to derive the log group path |
| `environment` | Deployment label: dev, staging, production |
| `alert_email` | Email for audit notifications |
| `incident_platform_url` | HTTPS webhook URL (Opsgenie, PagerDuty, VictorOps, etc.) |
| `log_retention_days` | CloudWatch retention window (default: 365) |

Terraform outputs the Lambda ARN, SNS topic ARN, KMS key ID, alarm name, and dashboard URL.

---

## Option 2: CLI scripts (single account / first-time)

Set environment variables, then run `deploy-all.sh`:

```bash
export AWS_PROFILE=your-aws-profile
export AWS_REGION=us-east-1
export ACCOUNT_ID=123456789012
export CLUSTER_NAME=your-aurora-cluster
export ALERT_EMAIL=engineering-team@your-company.com
export INCIDENT_PLATFORM_URL=https://your-platform/endpoint?apiKey=YOUR_KEY
export RETENTION_DAYS=365

chmod +x deploy-all.sh
./deploy-all.sh
```

`deploy-all.sh` runs all six steps in order:
1. `iam/deploy-iam.sh` — IAM role and permissions policy
2. `lambda/deploy-lambda.sh` — Lambda function
3. `eventbridge/deploy-eventbridge.sh` — 5-minute schedule
4. `sns/deploy-sns.sh` — SNS topic, KMS key, subscriptions
5. `cloudwatch/deploy-alarm.sh` — CloudWatch alarm
6. `cloudwatch/deploy-dashboard.sh` + `set-log-retention.sh`

Each script can also be run independently.

---

## Database Setup

Run `sql/pgaudit-setup.sql` against the Aurora cluster as the `postgres` superuser.

**Before running the SQL:**
1. Add `pgaudit` to `shared_preload_libraries` in the cluster parameter group
2. Reboot the cluster (required for `shared_preload_libraries` changes)

**Critical:** `shared_preload_libraries` loads the binary into shared memory. `CREATE EXTENSION pgaudit` registers it in the database catalog. Both are required — missing the extension install produces zero audit records and zero error messages. The cluster appears healthy but logs nothing.

Diagnostic if logs are empty after setup:
```sql
SELECT * FROM pg_extension WHERE extname = 'pgaudit';
-- Must return a row. 0 rows = extension not installed.
```

Enable per-user auditing for each individual human user:
```sql
ALTER USER your_username SET pgaudit.log TO 'all';

-- Verify
SELECT usename, useconfig FROM pg_user WHERE usename = 'your_username';
-- useconfig should show: {pgaudit.log=all}
```

See `sql/pgaudit-setup.sql` for the full script including verification queries.

---

## Lambda Configuration

`lambda/lambda_function.py` is driven entirely by environment variables — the same package deploys across all environments without code changes.

| Environment Variable | Default | Description |
|---|---|---|
| `LOG_GROUP_NAME` | `/aws/rds/cluster/your-aurora-cluster/postgresql` | CloudWatch log group for the cluster |
| `METRIC_NAMESPACE` | `RDSAudit/UserActivity` | Custom metric namespace |
| `QUERY_WINDOW_MINUTES` | `5` | Log Insights look-back window (should match EventBridge schedule) |

The Lambda publishes two metrics to `RDSAudit/UserActivity`:
- `UserDMLOperationCount` — count of filtered user DML operations per 5-minute window
- `MonitorExecutionErrors` — increments if the Lambda itself errors, so the monitor's health is observable

Lambda timeout must be set to **300 seconds**. Log Insights queries are async and can be slow on large log groups.

---

## SNS Security — Key Points

**`sns/topic-policy.json`** applies three statements:
- `AllowCloudWatchAlarms` — permits CloudWatch to publish, scoped to this account only via `aws:SourceAccount`
- `DenyInsecureTransport` — explicitly denies HTTP delivery; enforces HTTPS at the policy level
- `LimitToAccountOnly` — blocks cross-account publishing; prevents confused deputy attacks

**`sns/kms-key-policy.json`** — the `AllowCloudWatchAlarmsToUseKey` statement is critical.

The AWS-managed key `alias/aws/sns` **cannot** be used with CloudWatch Alarms. AWS managed key policies are immutable — you cannot grant CloudWatch `kms:GenerateDataKey`. The symptom is:

```
CloudWatch Alarms does not have authorization to access the SNS topic encryption key
```

The customer-managed key in this repo has an explicit CloudWatch service grant that resolves this. Note: the `alias/aws/sns` managed key works fine when Lambda publishes directly to SNS — the restriction is specific to the **CloudWatch Alarms → SNS** delivery path.

---

## The Noise Filter

The Log Insights query in `lambda/lambda_function.py` (also available standalone in `cloudwatch/log-insights-query.txt`) was built incrementally from observed production traffic.

Every database client tool (DBeaver, DataGrip, pgAdmin) fires a sequence of catalog queries on connect. Every JDBC driver runs initialization SELECTs. Every connection pool runs health checks. Without the exclusion filters, the alarm fires constantly on noise with no audit value — and alert fatigue makes the system worthless.

The exclusion list covers the most common patterns. Add exclusions specific to your application stack as you identify them.

---

## Incident Platform Deduplication

Most incident platforms (Opsgenie, PagerDuty, VictorOps) deduplicate by alarm name. If an alert with the same name is already open, subsequent triggers are suppressed.

`cloudwatch/deploy-alarm.sh` appends a Unix timestamp to the alarm name at deploy time (`rds-user-dml-detected-<epoch>`), generating a unique identifier per deployment.

For ongoing deduplication within a single alarm deployment, configure auto-close in the incident platform integration: when the CloudWatch alarm returns to OK state, the platform closes the incident, and the next ALARM transition creates a fresh one.

---

## When an Alert Fires

1. Acknowledge the alert in the incident platform
2. Open CloudWatch → Log Insights → select the cluster log group
3. Run the query from `cloudwatch/log-insights-query.txt` for a ±15 minute window around the alert timestamp
4. Parse the audit record to identify user, operation, and object:
   ```
   AUDIT: SESSION,<session_id>,<statement_id>,<class>,<command>,<object_type>,<object_name>,<statement>
   ```
5. Determine if the activity was expected (scheduled job, deployment, authorised access)
6. If unexpected: escalate to the application team and security team; check for correlated events in the same window
7. Document the finding and close or escalate the incident ticket

---

## Cost Estimate

Per Aurora cluster per month (us-east-1):

| Component | Monthly Cost |
|---|---|
| Lambda — 8,640 invocations (5-min schedule) | ~$0.09 |
| CloudWatch Log Insights queries | ~$2.50 |
| CloudWatch custom metric | ~$0.30 |
| CloudWatch alarm | ~$0.10 |
| SNS notifications | ~$0.01 |
| Customer-managed KMS key | ~$1.00 |
| **Total** | **~$3.00–$4.00 / cluster / month** |

---

## Operational Notes

**Log volume:** Minimal at this audit scope. Individual human users in a regulated environment are not expected to generate high transaction volumes — the audit target is ad-hoc access, not application traffic.

**Log retention:** Set via `cloudwatch/set-log-retention.sh` or the `log_retention_days` Terraform variable. Default is 365 days. Set to match your compliance requirement. CloudWatch default is indefinite retention if not explicitly configured.

**Lambda concurrency:** One invocation per cluster per 5 minutes. No concurrency concerns at this scale.

**Alarm initialisation:** The alarm shows `INSUFFICIENT_DATA` until the Lambda publishes its first metric data point. Invoke manually to initialise:
```bash
aws lambda invoke \
  --function-name rds-user-audit-monitor \
  --payload '{}' \
  response.json && cat response.json
```

---

## Related

- Dev.to article: https://dev.to/pranay_raavi/what-it-actually-takes-to-audit-aurora-postgresql-on-aws-l7j
- Medium article: https://medium.com/@pranayraavi/database-auditing-on-aws-aurora-postgresql-ee758aad3fe3
