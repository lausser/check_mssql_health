## Context

The `server::jobs::failed` mode in `plugins-scripts/CheckMssqlHealth/MSSQL/Component/JobSubsystem.pm` reports the latest job execution state for SQL Server Agent jobs. We investigated four real jobs on Microsoft SQL Server 2019: `IndexOptimize - USER_DATABASES`, `StatisticsUpdate`, `syspolicy_purge_history`, and `VulnerabilityManagement`.

The merged plugin output comes from three SQL sources:
- `msdb.dbo.sysjobs` for job identity and metadata
- `msdb.dbo.sysjobschedules` joined through `sysschedules` for next run information
- `msdb.dbo.sysjobhistory` for the most recent step 0 execution record

The confirmed data shows that `VulnerabilityManagement` really has a schedule row with `next_run_date = 20260701` and `next_run_time = 20000`, so `Jul 1 2026 02:00AM` belongs to that job and is not a JOIN artifact.

## Goals / Non-Goals

**Goals:**
- Keep `NextRunDateTime` as informational data, not a primary failure signal
- Preserve the existing priority of `lastrunstatus` for `failed-jobs`
- Handle the one special case where a job has never run and its next scheduled time is already in the past
- Keep the SQL Server 2019-compatible query shape and data model
- Leave the existing runtime-threshold path for successfully run jobs unchanged

**Non-Goals:**
- Do not change how job schedules are stored in SQL Server
- Do not rework the overall plugin architecture
- Do not change unrelated modes such as `list-jobs` or `jobs-enabled`
- Do not treat all never-run jobs as failures
- Do not alter the elapsed-runtime threshold comparison for jobs whose latest status is `Succeeded`

## Decisions

**Decision 1: Treat `NextRunDateTime` as informational, not filtering.**

The schedule timestamp is valid and belongs to the job, but it should not drive the default failed-jobs decision tree. The main signal remains `LastRunStatus`.

Alternatives considered:
- Filter on `NextRunDateTime` broadly: rejected because it would misclassify future-scheduled jobs.
- Ignore `NextRunDateTime` entirely: rejected because the never-run + past-schedule case is meaningful.

**Decision 2: Preserve the existing `sysjobs` -> `sysjobschedules` -> `sysschedules` correlation.**

The SQL Server 2019 data confirmed the JOIN path is correct for the inspected jobs. There is no evidence that `VulnerabilityManagement` received a timestamp from another job.

Alternatives considered:
- Rewrite the JOINs to chase a suspected schedule-mix bug: rejected for this case because the raw rows disproved that hypothesis.
- Replace the schedule JOIN with an aggregate over combined datetime: unnecessary for the observed data.

**Decision 3: Handle never-run jobs only when the next run is already in the past.**

The intended behavior is:
- `DidNeverRun` + future `NextRunDateTime` => OK
- `DidNeverRun` + past `NextRunDateTime` => WARNING
- Any other status => use `lastrunstatus` as the primary result
- `Succeeded` jobs still flow into the existing runtime-threshold check exactly as before

Alternatives considered:
- Exclude all never-run jobs: rejected because future-scheduled jobs are still valid and should remain OK.
- Flag all never-run jobs as warnings: rejected because planned future jobs are not failures.

**Decision 4: Keep SQL inspection as a debugging aid, not as the source of the final status.**

The raw-table queries are useful to reason about the merged result, but the final status should still be produced by the plugin logic.

## Risks / Trade-offs

[Risk] Misreading schedule timestamps as failure state -> Mitigation: keep `NextRunDateTime` informational except for the single overdue-never-run exception.

[Risk] SQL Server schedule rows can be confusing when multiple schedules exist -> Mitigation: validate the raw `sysjobschedules`/`sysschedules` rows before changing query logic.

[Risk] The current tasks/spec text still reflects the older assumption that never-run jobs should be excluded -> Mitigation: update the spec/tasks before implementation so the behavior stays aligned.

## Migration Plan

1. Keep the current SQL Server 2019-compatible inspection queries as the reference point.
2. Update the design/spec language to reflect the corrected status rule.
3. Adjust implementation so `DidNeverRun` remains OK unless the schedule is already in the past, in which case it becomes WARNING.
4. Verify with the four named jobs in the real database.

## Open Questions

- What exact message should the WARNING for overdue never-run jobs use?
- Should the warning mention `NextRunDateTime` explicitly, or only note that the job never executed?
- Do we want a dedicated test case for the overdue-never-run special case in the tasks list?
