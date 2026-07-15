## JOIN Analysis - Is NextRunDateTime Correctly Assigned?

### The Question

Is the `NextRunDateTime` value `'Jul  1 2026 02:00AM'` for job `VulnerabilityManagement` correct, 
or is it erroneously assigned through a buggy JOIN operation?

### Real Data Verification

Query executed against SQL Server:

```sql
SELECT 
    j.name AS JobName,
    j.job_id,
    s.next_run_date,
    s.next_run_time
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules s ON j.job_id = s.job_id
WHERE j.name = 'VulnerabilityManagement'
ORDER BY s.next_run_date, s.next_run_time;
```

**Result:**
```
JobName                   job_id                              next_run_date  next_run_time
VulnerabilityManagement   6D53DD32-0538-45FE-A494-47695BDAE522  20260701       020000
```

### Verification Result: JOIN IS CORRECT ✓

The data is accurate:
- Job `VulnerabilityManagement` has **ONE schedule**
- Schedule: `next_run_date = 20260701`, `next_run_time = 020000`
- Combined: `Jul 1 2026 02:00AM`

The LEFT JOIN is working correctly. The job ID in `sysjobschedules` matches the job in `sysjobs`.

### But There's Still a Problem!

```
Current time (plugin run):  Jul 13 2026 11:53AM
Job's NextRunDateTime:      Jul  1 2026 02:00AM
Time difference:            12 days ago!

Timeline:
Jul 1 2026 02:00AM  ───●───────────────────────────────●───►
                      ^                                 ^
                 Scheduled Run                    Current Time
                 (12 days ago!)                 (Plugin Run)

Status: Job is OVERDUE - it should have run 12 days ago!
```

### The REAL Issue: Logic, Not JOIN

The JOIN is correct, but the **business logic** is wrong:

**Current behavior:**
```perl
# For jobs without history, always report "DidNeverRun" as OK
if (! defined $self->{lastrundatetime}) {
    $self->add_ok(sprintf "%s did never run", $self->{name});
}
```

**The problem:** This treats ALL jobs without history the same way:
- Jobs scheduled in the PAST (overdue) → OK "did never run" ✗
- Jobs scheduled in the FUTURE (not due) → OK "did never run" ✗

Both should be EXCLUDED or reported differently!

### What Should Happen

For `failed-jobs` mode, we should:

1. **Jobs without history + PAST scheduled time** → OVERDUE (CRITICAL or WARNING)
2. **Jobs without history + FUTURE scheduled time** → EXCLUDE (not due yet)
3. **Jobs without history + NO schedule info** → EXCLUDE (no schedule)

### Why the MIN() Bug Discussion Was a Red Herring

I initially suspected the `MIN()` aggregation bug where separate date/time MIN() could produce invalid combinations. But the verification query proves:

- The job has only ONE schedule
- The MIN() returns the correct value for this case
- The JOIN correctly associates the schedule with the job

**So the MIN() issue is NOT the bug we're seeing.**

However, the MIN() approach IS theoretically flawed for jobs with MULTIPLE schedules. But that's a separate issue.

### Summary

| Aspect | Status |
|--------|--------|
| JOIN correctness | ✓ CORRECT |
| NextRunDateTime value | ✓ CORRECT (Jul 1 2026 02:00AM) |
| Business logic | ✗ WRONG (overdue jobs reported as OK) |

### The Real Fix

Update the `JobSubsystem::Job::check()` method for `failed-jobs` mode:

```perl
if ($self->mode =~ /server::jobs::failed/) {
    if (! defined $self->{lastrundatetime}) {
        # No execution history
        if (! defined $self->{nextrundatetime}) {
            # No schedule info - exclude from output
            return;
        } elsif ($self->{nextrundatetime} < CURRENT_TIME) {
            # Scheduled time is in the past - OVERDUE!
            $self->add_critical(sprintf "%s is OVERDUE! Scheduled for %s, never executed",
                $self->{name}, $self->{nextrundatetime});
        } else {
            # Scheduled time is in the future - not due yet, exclude
            return;
        }
    } elsif ($self->{lastrunstatus} eq "Failed") {
        # ... existing failure logic ...
    }
    # ... rest of logic ...
}
```

### Next Steps

1. **Update the spec** to reflect: overdue jobs should fail, not be OK
2. **Implement the new logic** in the check method
3. **Test with real data** to verify overdue jobs are detected
