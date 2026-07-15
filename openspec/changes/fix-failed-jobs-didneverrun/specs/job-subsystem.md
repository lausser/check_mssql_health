## MODIFIED Requirements

### Requirement: failed-jobs mode uses last run status as the primary signal
The `server::jobs::failed` mode SHALL evaluate the latest job execution status first. Jobs whose latest run status is `Failed` SHALL be reported as critical. Jobs whose latest run status is `Retry` or `Canceled` SHALL be reported as warning. Jobs whose latest run status is `Succeeded` SHALL continue through the existing runtime-threshold path unchanged.

#### Scenario: Job has failed
- **WHEN** a job has execution history and the latest `run_status` is `0`
- **THEN** the job is reported as CRITICAL
- **AND** the failure message includes the job name, failure datetime, and status message

#### Scenario: Job is retried or canceled
- **WHEN** a job has execution history and the latest `run_status` is `2` or `3`
- **THEN** the job is reported as WARNING
- **AND** the message includes the job name and the latest status message

#### Scenario: Job succeeded
- **WHEN** a job has execution history and the latest `run_status` is `1`
- **THEN** the job continues through the existing runtime-threshold check
- **AND** the success path remains unchanged from current behavior

### Requirement: DidNeverRun jobs are normally OK
The `server::jobs::failed` mode SHALL report a job with `DidNeverRun` as OK when the job has no execution history and its next scheduled run is still in the future. The next run timestamp is informational and SHALL NOT otherwise affect the result.

#### Scenario: Never-run job with future schedule
- **WHEN** a job has no execution history and `nextrundatetime` is in the future
- **THEN** the job is reported as OK
- **AND** the result indicates the job did never run

#### Scenario: Never-run job with past schedule
- **WHEN** a job has no execution history and `nextrundatetime` is in the past
- **THEN** the job is reported as WARNING
- **AND** the message indicates the job did never run but is overdue

#### Scenario: Never-run job with no schedule timestamp
- **WHEN** a job has no execution history and `nextrundatetime` is undefined
- **THEN** the job is reported as OK
- **AND** the next run timestamp remains informational only

### Requirement: Job history JOIN logic for latest execution
The SQL query SHALL use LEFT JOIN with sysjobhistory to get the most recent execution for each job. Jobs without history SHALL keep NULL values for the history columns and SHALL be interpreted by the check logic as `DidNeverRun`.

#### Scenario: SQL query with execution history
- **WHEN** the SQL query retrieves job history
- **THEN** the subquery for latest execution includes `WHERE [step_id] = 0`
- **AND** the resulting history set contains the latest step 0 row per job
- **AND** jobs without history have NULL values in the joined history columns
