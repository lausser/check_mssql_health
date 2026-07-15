## Summary of Findings

### Problem Statement

When running `check_mssql_health --mode failed-jobs`, jobs that have never been executed are reported with status "DidNeverRun" as OK, when they should be detected as OVERDUE if their scheduled time is in the past.

### Root Cause Analysis

#### What Was Verified
✓ The SQL JOIN is **CORRECT**
- `VulnerabilityManagement` job ID: `6D53DD32-0538-45FE-A494-47695BDAE522`
- Scheduled time: `Jul 1 2026 02:00AM` (correctly retrieved from `sysjobschedules`)
- The job has only ONE schedule (MIN() bug was not the issue)

#### What Was NOT Correct
✗ The business logic treats all "DidNeverRun" jobs the same way
- Overdue jobs (past scheduled time) → Currently OK, should be CRITICAL/WARNING
- Future-scheduled jobs (future scheduled time) → Currently OK, should be EXCLUDED

### Real Data Example

```
Job: VulnerabilityManagement
Current time (plugin run):  Jul 13 2026 11:53AM
Scheduled time:             Jul  1 2026 02:00AM (12 days ago!)
Execution history:          NONE (never ran)

Current output:
  "VulnerabilityManagement did never run" (OK status)
  
Expected output:
  "VulnerabilityManagement is OVERDUE! Scheduled for Jul 1 2026 02:00AM, never executed"
  (CRITICAL or WARNING status)
```

### Jobs in Test Data

| Job | LastRunStatus | NextRunDateTime | Decision |
|-----|---------------|-----------------|----------|
| IndexOptimize - USER_DATABASES | Failed | Jul 13 2026 10:00PM | CRITICAL (has history, failed) |
| syspolicy_purge_history | Succeeded | Jul 14 2026 02:00AM | OK (has history, succeeded, within lookback) |
| VulnerabilityManagement | DidNeverRun | Jul 1 2026 02:00AM | **OVERDUE** (no history, past schedule) |

### Required Changes

1. **Update spec** (`specs/job-subsystem.md`):
   - Change: "failed-jobs mode excludes jobs that have never run"
   - To: "failed-jobs mode detects overdue jobs (past scheduled time, no history)"

2. **Update implementation** (`JobSubsystem.pm`):
   - Modify `JobSubsystem::Job::check()` method
   - For jobs without history:
     - Check if `nextrundatetime` is defined
     - If past → CRITICAL/WARNING (overdue)
     - If future → EXCLUDE (not due yet)
     - If undefined → EXCLUDE (no schedule)

3. **Update tasks** (`tasks.md`):
   - Add tasks for overdue job detection logic

### Decision Points

1. **Should overdue jobs be CRITICAL or WARNING?**
   - I recommend: CRITICAL (job failed to run when it should have)

2. **Should future-scheduled jobs be excluded?**
   - I recommend: YES (not due yet, so not relevant for "failed-jobs" check)

3. **Should lookback apply to overdue jobs?**
   - I recommend: NO (overdue jobs should always be reported, regardless of lookback)

### Verification Commands

To verify the fix works:

```bash
# Test with --mode failed-jobs
./check_mssql_health --mode failed-jobs --hostname <server> --username <user> --password <pass>

# Expected: VulnerabilityManagement should show as CRITICAL/WARNING (overdue)
# Expected: IndexOptimize should show as CRITICAL (failed)
# Expected: syspolicy_purge_history should show as OK (succeeded, within lookback)
```

### Files Created for Exploration

- `real-data.md` - Original debug output from plugin
- `join-analysis.md` - Verification that JOIN is correct
- `overdue-jobs.md` - Analysis of overdue job logic
- `this-summary.md` - This summary of findings

### Next Steps (When Ready to Implement)

1. Review the spec and ensure it captures the new requirements
2. Implement the overdue job detection logic
3. Test with real database
4. Archive the change with `/opsx-archive`
