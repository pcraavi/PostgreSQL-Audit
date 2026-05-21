-- =============================================================================
-- pgAudit Setup Script
-- Aurora PostgreSQL -- Individual User Audit Configuration
-- =============================================================================
--
-- BEFORE running this script:
--   1. Add 'pgaudit' to shared_preload_libraries in the cluster parameter group
--   2. Reboot the cluster (required for shared_preload_libraries changes)
--   3. Then run this script as the postgres superuser
--
-- WHY shared_preload_libraries alone is not enough:
--   shared_preload_libraries loads the binary into shared memory.
--   CREATE EXTENSION registers it in the database catalog.
--   Both are required. Missing CREATE EXTENSION produces zero audit records
--   and zero error messages -- the cluster appears healthy but logs nothing.
--   Diagnosed by: SELECT * FROM pg_extension WHERE extname = 'pgaudit';
--   returning 0 rows.
-- =============================================================================


-- Step 1: Install the extension (run once per database)
CREATE EXTENSION IF NOT EXISTS pgaudit;

-- Verify installation
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name = 'pgaudit';
-- installed_version should be populated. If NULL: available but not installed.


-- =============================================================================
-- Step 2: Enable per-user audit logging
--
-- Audit scope: individual human users only.
-- Application service accounts are deliberately excluded.
-- Their DML is expected and would generate enormous noise.
--
-- Audit target: direct human access to production data.
-- Risk surface: developer via psql, support engineer ad-hoc query,
--               credential that should not have had direct DB access.
-- =============================================================================

-- Enable full audit logging for an individual user
ALTER USER your_username SET pgaudit.log TO 'all';

-- Verify
SELECT usename, useconfig
FROM pg_user
WHERE usename = 'your_username';
-- useconfig should show: {pgaudit.log=all}

-- Repeat for each individual human user with direct database access:
-- ALTER USER user_two   SET pgaudit.log TO 'all';
-- ALTER USER user_three SET pgaudit.log TO 'all';


-- =============================================================================
-- Step 3: Verification
-- =============================================================================

-- Confirm extension is installed
SELECT * FROM pg_extension WHERE extname = 'pgaudit';

-- Check active pgaudit settings
SHOW pgaudit.log;

-- List all users with pgaudit enabled
SELECT usename, useconfig
FROM pg_user
WHERE useconfig::text LIKE '%pgaudit%';


-- =============================================================================
-- Step 4: Disable auditing for a user (if needed)
-- =============================================================================
-- ALTER USER your_username RESET pgaudit.log;
