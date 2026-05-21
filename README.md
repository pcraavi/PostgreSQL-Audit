# Aurora PostgreSQL User Audit Monitoring

> Detect and alert on individual user DML activity (SELECT, INSERT, UPDATE, DELETE) on Aurora PostgreSQL clusters using pgAudit, Lambda, CloudWatch, and SNS.

---

## What This Does

In regulated environments, the audit question isn't whether to log — it's *who* to log. Application service accounts are expected to read and write data. The risk surface is **direct human access**: a developer connected via psql, a support engineer running an ad-hoc update, a credential that should never have had direct database access.

This solution:
- Enables pgAudit logging scoped to individual human user accounts
- Filters system and tool noise (DBeaver, JDBC driver init, pg_catalog queries) from the raw CloudWatch log stream
- Bridges CloudWatch Log Insights to CloudWatch Alarms via Lambda (they cannot connect natively)
- Alerts through your incident management platform and email on every detection window where user DML is found
- Provides timestamped Lambda execution logs as an independent, durable record of detection — useful for compliance reviews

---

## Architecture

```
Aurora PostgreSQL  (pgAudit per-user logging)
        │
        ▼
CloudWatch Logs   /aws/rds/cluster/<cluster>/postgresql
        │
        ├──► CloudWatch Dashboard  (real-time Log Insights view)
        │
EventBridge  rate(5 minutes)
        │
        ▼
Lambda Function
  ├── Runs Log Insights query (last 5 min window)
  ├── Filters system/tool noise
  ├── Counts user DML: SELECT / INSERT / UPDATE / DELETE
  └── Publishes metric → RDSAudit/UserActivity namespace
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

---

## Repository Structure

```
├── README.md
├── lambda/
│   └── lambda_function.py          # Core audit monitor Lambda
├── iam/
│   ├── lambda-trust-policy.json    # Lambda execution role trust policy
│   └── lambda-permissions.md       # Required IAM permissions reference
├── sns/
│   ├── topic-policy.json           # SNS resource policy (HTTPS enforcement, account lock-down)
│   └── kms-key-policy.json         # Customer-managed KMS key policy with CloudWatch grant
├── cloudwatch/
│   ├── alarm.sh                    # CloudWatch alarm creation script
│   ├── dashboard.json              # CloudWatch dashboard definition
│   └── log-insights-query.txt      # Standalone filter query for manual use
├── eventbridge/
│   └── schedule.sh                 # EventBridge rule and target setup
├── terraform/                      # (coming) Full Terraform module
│   └── README.md
└── docs/
    ├── pgaudit-setup.md            # pgAudit enablement steps
    ├── sns-security.md             # SNS HTTPS + KMS configuration detail
    ├── kms-gotcha.md               # alias/aws/sns + CloudWatch Alarms issue explained
    ├── deduplication.md            # Incident platform deduplication behavior and fixes
    └── alert-runbook.md            # What to do when an alert fires
```

---

## Prerequisites

- Aurora PostgreSQL cluster with parameter group access
- AWS CLI configured with appropriate permissions
- Python 3.9+ (Lambda runtime)
- Incident management platform with HTTPS webhook support (Opsgenie, PagerDuty, VictorOps, etc.)

### Required IAM permissions for Lambda execution role

```
# Read permissions
logs:StartQuery
logs:GetQueryResults
logs:DescribeLogGroups

# Write permissions  
cloudwatch:PutMetricData

# Basic Lambda execution
logs:CreateLogGroup
logs:CreateLogStream
logs:PutLogEvents
```

> Full IAM role setup: see `iam/lambda-permissions.md`

---

## Quick Start

### Step 1: Enable pgAudit on the Aurora cluster

Add `pgaudit` to `shared_preload_libraries` in the cluster parameter group. **Requires cluster reboot.**

Then in the database:

```sql
-- Install the extension (required — shared_preload_libraries alone is not enough)
CREATE EXTENSION pgaudit;

-- Enable per-user audit logging for each individual human user
ALTER USER <username> SET pgaudit.log TO 'all';

-- Verify
SELECT usename, useconfig FROM pg_user WHERE usename = '<username>';
```

> **Critical:** `shared_preload_libraries` loads the binary. `CREATE EXTENSION` registers it. Both are required. Missing the extension install produces zero audit records and zero error messages.

### Step 2: Enable CloudWatch log export

RDS Console → your cluster → Modify → Additional configuration → Log exports → enable **PostgreSQL log**.

Logs flow to: `/aws/rds/cluster/<cluster-name>/postgresql`

### Step 3: Deploy Lambda

```bash
cd lambda/
zip audit_monitor.zip lambda_function.py

# Set environment variable for your cluster's log group
export LOG_GROUP=/aws/rds/cluster/YOUR-CLUSTER/postgresql
export ACCOUNT_ID=YOUR_ACCOUNT_ID
export REGION=us-east-1

# See iam/ for role creation
# See eventbridge/ for schedule setup
```

> Full CLI deployment: see individual scripts in `iam/`, `eventbridge/`, `cloudwatch/`  
> Terraform deployment: see `terraform/` (coming)

### Step 4: Configure SNS topic

The SNS topic requires:
1. Resource policy enforcing HTTPS-only delivery (`DenyInsecureTransport`)
2. Source account restriction to block cross-account publishing
3. Customer-managed KMS key for encryption at rest

> **KMS gotcha:** You cannot use `alias/aws/sns` (AWS-managed key) with CloudWatch Alarms. AWS managed key policies are immutable — CloudWatch cannot be granted `kms:GenerateDataKey`. Use a customer-managed key with an explicit CloudWatch service grant. See `docs/kms-gotcha.md`.

### Step 5: Handle incident platform deduplication

Most incident platforms (Opsgenie, PagerDuty, VictorOps) deduplicate alerts by alarm name. The first alert fires; subsequent ones are suppressed if the incident is still open.

Fix options:
- Timestamp the alarm name at deploy time (`$(date +%s)` suffix)
- Configure auto-close when alarm returns to OK state
- Override the alias template in the integration config

> Detail: see `docs/deduplication.md`

---

## The Log Insights Filter Query

The core signal filter. Targets user DML on application tables, excluding system catalog queries and tool initialization noise:

```
fields @timestamp, @message, @logStream, @log
| filter @message like /AUDIT:/
| filter (
    @message like /SELECT/ or
    @message like /INSERT/ or
    @message like /UPDATE/ or
    @message like /DELETE/
  )
| filter @message not like /SELECT version()/
| filter @message not like /pg_shdescription/
| filter @message not like /pg_database/
| filter @message not like /pg_catalog/
| filter @message not like /information_schema/
| filter @message not like /SET application_name/
| filter @message not like /SHOW search_path/
| filter @message not like /SELECT current_schema/
| filter @message not like /DBeaver/
| filter @message not like /PostgreSQL JDBC Driver/
| filter @message not like /datname = \$1/
| sort @timestamp desc
```

Your exclusion list will grow. Every application stack generates its own connection initialization patterns — add them as you observe them in your environment.

---

## Operational Notes

### pgAudit overhead

Overhead is minimal when audit scope is limited to individual human users. Human users in a regulated production environment are not expected to generate high transaction volumes — the audit target is ad-hoc access, not application traffic. Log volume at this scope is low and adds negligible performance impact.

For high-volume clusters: size the instance with audit overhead in mind, and set CloudWatch log retention to match your compliance window rather than keeping logs indefinitely.

### Log Insights query behavior

Log Insights queries are asynchronous. The Lambda polls for completion with a 60-second timeout and a 300-second function timeout. On very high log volumes, initial query runs may be slower — this is a one-time warm-up effect as CloudWatch indexes the log group.

Lambda runs on a 5-minute EventBridge schedule. Concurrency is inherently low — one invocation per cluster per 5 minutes. No concurrency concerns at this scale.

### CloudWatch log retention

Set explicitly. Default is indefinite retention, which accumulates cost. Retention window should be defined by your compliance requirements (90 days, 1 year, 7 years). Apply via:

```bash
aws logs put-retention-policy \
  --log-group-name /aws/rds/cluster/YOUR-CLUSTER/postgresql \
  --retention-in-days 365
```

---

## Why This Approach Over Alternatives

**Database Activity Streams (DAS):** DAS provides near-real-time activity streaming to Kinesis but requires additional infrastructure (Kinesis consumer, decryption layer) and adds cost per event. pgAudit + CloudWatch uses infrastructure most AWS teams already operate. For teams without a dedicated Kinesis pipeline, DAS adds meaningful operational surface area for a problem pgAudit already solves natively.

**GuardDuty RDS Protection:** Focused on threat detection (credential anomalies, known malicious IPs), not structured audit trails. Complementary, not equivalent.

**OpenSearch subscription filters:** Introduces an OpenSearch cluster as a dependency — additional cost, additional operational surface. The CloudWatch + Lambda approach keeps the audit pipeline within services the cluster already depends on.

The guiding principle: use the native, portable solution first. pgAudit is part of PostgreSQL. CloudWatch is where Aurora logs land regardless. Lambda and SNS are general-purpose. No proprietary tooling, no steep learning curve for teams with standard AWS operational knowledge.

---

## When an Alert Fires

1. Acknowledge the alert in the incident platform
2. Open CloudWatch → Log Insights → select the cluster log group
3. Run the user DML filter query for a ±15 minute window around the alert timestamp
4. Parse the audit record format:
   ```
   AUDIT: SESSION,<session_id>,<statement_id>,<class>,<command>,<object_type>,<object_name>,<statement>
   ```
5. Determine if the activity was expected (scheduled job, deployment, authorized access)
6. If unexpected: escalate to application team and security team; examine correlated events in the same window
7. Document the finding and close or escalate the incident ticket

> Full runbook: see `docs/alert-runbook.md`

---

## Cost Estimate

Per Aurora cluster per month (us-east-1):

| Component | Monthly Cost |
|-----------|-------------|
| Lambda — 8,640 invocations (5-min schedule) | ~$0.09 |
| CloudWatch Log Insights queries | ~$2.50 |
| CloudWatch custom metric | ~$0.30 |
| CloudWatch alarm | ~$0.10 |
| SNS notifications | ~$0.01 |
| Customer-managed KMS key | ~$1.00 |
| **Total** | **~$3.00–$4.00/month per cluster** |

The full stack fits in a parameterized Terraform module — cluster name, account ID, log group, and notification endpoint as variables. Deploying to additional accounts is a single `terraform apply`.

---

## Related Articles

- [Dev.to: What It Actually Takes to Audit Aurora PostgreSQL on AWS](#) *(link when published)*
- [Medium: Rebuilding Oracle-Style Database Auditing on Aurora PostgreSQL](#) *(link when published)*

---

## License

MIT
