## JobSubsystem.pm Analysis

### Problem Statement
The `failed-jobs` mode reports jobs that have never run as "DidNeverRun" with OK status, which is confusing. Users expect this mode to ONLY show actually failed jobs.

### Root Cause Analysis

#### SQL Query Flow
```
FROM sysjobs (sJOB)
     LEFT JOIN sysjobhistory (sJOBH) 
       ON job_id = job_id AND RowNumber = 1
```

The LEFT JOIN means:
- Jobs WITH history: sJOBH fields populated
- Jobs WITHOUT history: sJOBH fields = NULL

#### Status Assignment (line 39-46)
```sql
CASE [sJOBH].[run_status]
    WHEN 0 THEN 'Failed'
    WHEN 1 THEN 'Succeeded'
    WHEN 2 THEN 'Retry'
    WHEN 3 THEN 'Canceled'
    WHEN 4 THEN 'Running'
    ELSE 'DidNeverRun'  -- NULL run_status falls here
END
```

#### Filter Logic (line 99)
```perl
sub { $self->opts->lookback; my $o = shift; 
      $self->filter_name($o->{name}) && 
      (! defined $o->{minutessincestart} || $o->{minutessincestart} <= $self->opts->lookback) 
}
```

This filter INCLUDES jobs where `minutessincestart` is undefined (never ran).

#### Check Method (line 203-205)
```perl
if (! defined $self->{lastrundatetime}) {
  $self->add_ok(sprintf "%s did never run", $self->{name});
}
```

For `failed-jobs` mode, this adds an OK message for jobs that never ran.

### Solution

#### Approach: Mode-Aware WHERE Clause

**For `failed-jobs` mode:**
```sql
LEFT JOIN (
    SELECT job_id, run_date, run_time, run_status, run_duration, message,
           ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY run_date DESC, run_time DESC) AS RowNumber
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0
) AS [sJOBH]
ON [sJOB].[job_id] = [sJOBH].[job_id]
AND [sJOBH].[RowNumber] = 1
-- ADD: Filter out jobs without history
WHERE [sJOBH].[run_date] IS NOT NULL
```

**For `enabled` and `list` modes:**
Keep current behavior (include all jobs).

### Implementation Plan

#### 1. Split SQL Query by Mode
```perl
if ($self->mode =~ /server::jobs::(failed|enabled|list)/) {
    $self->override_opt('lookback', 30) if ! $self->opts->lookback;
    if ($self->version_is_minimum("9.x")) {
        my $columns = [...];
        my $sql;
        
        if ($self->mode =~ /server::jobs::failed/) {
            # Query for failed-jobs: exclude jobs without history
            $sql = q{... WHERE [sJOBH].[run_date] IS NOT NULL ...};
        } else {
            # Query for enabled/list: include all jobs
            $sql = q{...};  # current query without WHERE
        }
        
        $self->get_db_tables([['jobs', $sql, ...]]);
    }
}
```

#### 2. Update Job::check() Method
For `failed-jobs` mode, skip jobs where `lastrundatetime` is undefined:
```perl
if ($self->mode =~ /server::jobs::failed/) {
    if (! defined $self->{lastrundatetime}) {
        # Skip jobs that never ran - they're not in the query result anyway
        return;
    }
    # ... rest of check logic
}
```

### Testing Strategy

#### Test Scenario 1: Jobs with No History
- Create job "NeverRunJob" (no executions in sysjobhistory)
- Run: `check_mssql_health --mode failed-jobs`
- **Expected:** Job NOT in output
- **Actual (current):** "NeverRunJob did never run" (OK)

#### Test Scenario 2: Failed Job
- Create job "FailedJob" with latest run_status = 0 (Failed)
- Run: `check_mssql_health --mode failed-jobs`
- **Expected:** CRITICAL with job name, failure time, message
- **Actual (current):** CRITICAL ✓

#### Test Scenario 3: Succeeded Job
- Create job "SucceededJob" with latest run_status = 1 (Succeeded)
- Run: `check_mssql_health --mode failed-jobs`
- **Expected:** OK with runtime metrics (if within lookback)
- **Actual (current):** OK with runtime metrics ✓

#### Test Scenario 4: Mix of Jobs
- Job A: Failed
- Job B: Succeeded
- Job C: Never run
- Run: `check_mssql_health --mode failed-jobs`
- **Expected:** CRITICAL (Job A), no mention of Job C
- **Actual (current):** CRITICAL (Job A), plus "Job C did never run"

### Risk Assessment

**Risk 1:** Jobs that started outside lookback but have history
- **Current:** Included (if they ran within lookback window based on `minutessincestart`)
- **After fix:** Still included (WHERE clause is `run_date IS NOT NULL`)
- **Mitigation:** The existing lookback filter in the callback handles this

**Risk 2:** Other modes affected
- **Current:** `enabled` and `list` modes use same SQL
- **After fix:** They get different SQL queries
- **Mitigation:** Explicit mode check ensures modes don't interfere

**Risk 3:** Existing tests break
- **Mitigation:** Test each mode separately before and after
