## 1. SQL Query Fix

- [x] 1.1 Verify the sysjobschedules join returns the correct next_run_date and next_run_time for the four inspected jobs
- [x] 1.2 Confirm the failed-jobs SQL still returns the latest step 0 history row per job
- [x] 1.3 Test the SQL query against jobs with history, jobs with no history, and jobs with future schedules

## 2. Perl Check Method Update

 - [x] 2.1 Keep the existing runtime-threshold path unchanged for jobs whose latest status is Succeeded
 - [x] 2.2 Update the JobSubsystem::Job check method so DidNeverRun remains OK unless the next run is already in the past
 - [x] 2.3 Emit WARNING for the overdue never-run case and leave all other DidNeverRun jobs as OK
- [x] 2.4 Test the check method with failed, succeeded, retry, canceled, and never-run job states

## 3. Testing

- [x] 3.1 Create or reuse a SQL Server 2019 test database with sample jobs including the four inspected jobs
- [x] 3.2 Verify failed-jobs mode reports failed jobs as CRITICAL and succeeded jobs through the runtime-threshold path
- [ ] 3.3 Verify DidNeverRun jobs are OK when the next run is in the future
- [ ] 3.4 Verify DidNeverRun jobs are WARNING when the next run is in the past
- [x] 3.5 Verify other job modes (enabled, list) still work correctly

## 4. Documentation

 - [x] 4.1 Update plugin documentation to clarify that NextRunDateTime is informational except for the overdue never-run case
 - [x] 4.2 Add comment in JobSubsystem.pm explaining the DidNeverRun and runtime-threshold handling
 - [x] 4.3 Update CHANGELOG if applicable
