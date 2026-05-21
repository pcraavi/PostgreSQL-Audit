"""
Aurora PostgreSQL User Audit Monitor
--------------------------------------
Runs a CloudWatch Log Insights query every 5 minutes against the Aurora
PostgreSQL audit log group. Filters to individual-user DML operations
(SELECT/INSERT/UPDATE/DELETE), excludes system and tool noise, and publishes
a custom CloudWatch metric: UserDMLOperationCount.

A CloudWatch Alarm evaluates that metric and triggers SNS notifications
to the incident management platform and email.

Lambda execution logs serve as an independent timestamped record of every
detection event — separate from and corroborating the raw pgAudit log stream.
This matters when a compliance review asks "when was this first detected?"

Environment Variables:
    LOG_GROUP_NAME       - CloudWatch log group for the Aurora cluster
                           e.g. /aws/rds/cluster/my-aurora-cluster/postgresql
    METRIC_NAMESPACE     - CloudWatch custom metric namespace
                           default: RDSAudit/UserActivity
    QUERY_WINDOW_MINUTES - Look-back window in minutes
                           default: 5
"""

import boto3
import json
import os
from datetime import datetime, timedelta
import time

# ---------------------------------------------------------------------------
# Configuration — driven by environment variables so the same package deploys
# across multiple environments and accounts without code changes
# ---------------------------------------------------------------------------

LOG_GROUP_NAME       = os.environ.get('LOG_GROUP_NAME', '/aws/rds/cluster/your-aurora-cluster/postgresql')
METRIC_NAMESPACE     = os.environ.get('METRIC_NAMESPACE', 'RDSAudit/UserActivity')
QUERY_WINDOW_MINUTES = int(os.environ.get('QUERY_WINDOW_MINUTES', '5'))

# ---------------------------------------------------------------------------
# CloudWatch Log Insights query
#
# Targets: SELECT / INSERT / UPDATE / DELETE by individual users
# Excludes: system catalog queries, tool init sequences, connection health checks
#
# The exclusion list was built incrementally from observed production traffic.
# Every database client tool (DBeaver, DataGrip, pgAdmin) fires catalog queries
# on connect; every JDBC driver runs initialization SELECTs. Without these
# filters the alarm fires constantly on noise with no audit value.
#
# Add patterns specific to your application stack as you identify them.
# ---------------------------------------------------------------------------

AUDIT_FILTER_QUERY = """
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
| filter @message not like /datname = \\$1/
| stats count()
"""

QUERY_POLL_INTERVAL_SECONDS = 2
QUERY_POLL_MAX_SECONDS      = 60


def lambda_handler(event, context):
    logs_client = boto3.client('logs')
    cloudwatch  = boto3.client('cloudwatch')

    end_time   = datetime.utcnow()
    start_time = end_time - timedelta(minutes=QUERY_WINDOW_MINUTES)

    print(f"Log group : {LOG_GROUP_NAME}")
    print(f"Window    : {start_time.isoformat()} UTC  ->  {end_time.isoformat()} UTC")

    try:
        count = _run_insights_query(logs_client, start_time, end_time)
        _publish_count_metric(cloudwatch, count, end_time)
        print(f"Result: {count} user DML operation(s) detected in the last {QUERY_WINDOW_MINUTES} minutes")

        return {
            'statusCode': 200,
            'body': json.dumps({
                'operationCount': count,
                'windowStart'   : start_time.isoformat(),
                'windowEnd'     : end_time.isoformat(),
                'logGroup'      : LOG_GROUP_NAME,
            })
        }

    except Exception as exc:
        print(f"ERROR: {exc}")
        _publish_error_metric(cloudwatch, end_time)
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(exc)})
        }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_insights_query(logs_client, start_time, end_time):
    """Submit the Log Insights query and poll until complete."""

    response = logs_client.start_query(
        logGroupName=LOG_GROUP_NAME,
        startTime=int(start_time.timestamp()),
        endTime=int(end_time.timestamp()),
        queryString=AUDIT_FILTER_QUERY,
    )
    query_id = response['queryId']
    print(f"Query submitted: {query_id}")

    elapsed = 0
    while elapsed < QUERY_POLL_MAX_SECONDS:
        time.sleep(QUERY_POLL_INTERVAL_SECONDS)
        elapsed += QUERY_POLL_INTERVAL_SECONDS

        result = logs_client.get_query_results(queryId=query_id)
        status = result['status']

        if status == 'Complete':
            rows  = result.get('results', [])
            count = int(rows[0][0]['value']) if rows and rows[0] else 0
            print(f"Query complete: {count} record(s) matched (elapsed {elapsed}s)")
            return count

        if status in ('Failed', 'Cancelled'):
            raise RuntimeError(f"Log Insights query ended with status '{status}'")

        print(f"Query status: {status} ({elapsed}s elapsed)")

    raise TimeoutError(f"Log Insights query did not complete within {QUERY_POLL_MAX_SECONDS}s")


def _publish_count_metric(cloudwatch, count, timestamp):
    """Publish UserDMLOperationCount to the custom namespace."""
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            'MetricName': 'UserDMLOperationCount',
            'Value'     : count,
            'Unit'      : 'Count',
            'Timestamp' : timestamp,
            'Dimensions': [
                {'Name': 'LogGroup',      'Value': LOG_GROUP_NAME},
                {'Name': 'OperationType', 'Value': 'UserDMLFiltered'},
            ],
        }]
    )
    print(f"Metric published: UserDMLOperationCount = {count}")


def _publish_error_metric(cloudwatch, timestamp):
    """Publish an error counter so the monitor's own health is observable."""
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            'MetricName': 'MonitorExecutionErrors',
            'Value'     : 1,
            'Unit'      : 'Count',
            'Timestamp' : timestamp,
        }]
    )
    print("Error metric published: MonitorExecutionErrors = 1")
