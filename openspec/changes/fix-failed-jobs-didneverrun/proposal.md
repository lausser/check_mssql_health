## Why

When running `check_mssql_health` with `--mode failed-jobs`, jobs that have never been executed are incorrectly showing status `DidNeverRun` instead of being properly filtered out or reported. This appears to be caused by incorrect JOIN operations in the JobSubsystem.pm SQL query that don't correctly handle jobs without execution history.

## What Changes

- Fix the SQL JOIN logic in `plugins-scripts/CheckMssqlHealth/MSSQL/Component/JobSubsystem.pm` to correctly identify jobs that have never run
- The JOIN with `sysjobhistory` should properly filter for jobs without any execution history
- Jobs with status `DidNeverRun` should either be excluded from failed-jobs mode or handled differently

## Capabilities

### New Capabilities
- None

### Modified Capabilities
- `job-subsystem`: The SQL query logic for retrieving job information needs to be corrected to properly handle jobs without execution history in failed-jobs mode

## Impact

- Affected code: `plugins-scripts/CheckMssqlHealth/MSSQL/Component/JobSubsystem.pm` (lines 13-97)
- The JOIN operations in the SQL query (lines 61-94) need to be fixed to correctly identify jobs that have never run
- This affects the `server::jobs::failed` mode which should only report actually failed jobs, not jobs that have never executed
