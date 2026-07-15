## Overdue Job Detection Logic

### Key Finding from Real Data

Job: `VulnerabilityManagement`
- Current time (plugin run): `Jul 13 2026 11:53AM`
- NextRunDateTime: `Jul  1 2026 02:00AM` (12 days ago!)
- LastRunDateTime: `undef` (never executed)

```
Timeline:
Jul 1 2026 02:00AM  ───●───────────────────────●──────────────►
                      ^                         ^
                 Scheduled Run            Current Time
                 (OVERDUE!)             (Plugin Run)
                 
Status: Job should have run 12 days ago but never executed!
```

### Current Behavior vs Expected Behavior

**Current behavior:**
```
--mode failed-jobs output:
"VulnerabilityManagement did never run" (OK status)

Problem: Job is OVERDUE, not just "never ran"!
```

**Expected behavior for `failed-jobs` mode:**
```
Option 1: CRITICAL
"VulnerabilityManagement is overdue! Scheduled for Jul 1 2026 02:00AM, never executed"

Option 2: WARNING  
"VulnerabilityManagement is overdue! Scheduled for Jul 1 2026 02:00AM, never executed"

Option 3: Include in report with clear "OVERDUE" status
```

### Decision Tree for failed-jobs Mode

```
┌────────────────────────────────────────────────────────────┐
│  Decision Tree for Each Job                                │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  Step 1: Does job have execution history?                  │
│    ├─ YES → Go to Step 2                                   │
│    └─ NO → Go to Step 3 (no history)                       │
│                                                            │
│  Step 2: Check latest execution status                     │
│    ├─ run_status = 0 (Failed)   → CRITICAL                │
│    ├─ run_status = 2 (Retry)    → WARNING                 │
│    ├─ run_status = 3 (Canceled) → WARNING                 │
│    └─ run_status = 1 (Succeeded) → OK (check runtime)     │
│                                                            │
│  Step 3: No execution history                              │
│    ├─ Check nextrundatetime                                │
│    │   ├─ NULL/undef → EXCLUDE (no schedule info)         │
│    │   ├─ Past date → OVERDUE (should have run!)          │
│    │   └─ Future date → EXCLUDE (not due yet)             │
│    └─ Check minutessincestart                              │
│        └─ If defined, check lookback window                │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### Analysis of Real Data Jobs

#### Job 1: IndexOptimize - USER_DATABASES
```
NextRunDateTime: 'Jul 13 2026 10:00PM'  (future - 10:00 PM today)
LastRunDateTime: 'Jul 12 2026 10:00PM'  (past - 1 day ago)
LastRunStatus: 'Failed' (run_status = 0)
MinutesSinceStart: 833

Decision: Has history, status = Failed → CRITICAL ✓
```

#### Job 2: syspolicy_purge_history
```
NextRunDateTime: 'Jul 14 2026 02:00AM'  (future - tomorrow)
LastRunDateTime: 'Jul 13 2026 02:00AM'  (past - 9.9 hours ago)
LastRunStatus: 'Succeeded' (run_status = 1)
MinutesSinceStart: 593

Decision: Has history, status = Succeeded, within lookback → OK ✓
```

#### Job 3: VulnerabilityManagement
```
NextRunDateTime: 'Jul  1 2026 02:00AM'  (PAST - 12 days ago!)
LastRunDateTime: undef (never executed)
LastRunStatus: 'DidNeverRun' (run_status = NULL)
MinutesSinceStart: undef

Decision: NO history, NextRunDateTime is PAST → OVERDUE!
Current output: "did never run" (OK) ← WRONG!
Expected output: Should be CRITICAL/WARNING for overdue job
```

### Implications for the Fix

The current proposal was to **exclude** jobs without history from `failed-jobs` mode.

**But this is WRONG!** We should:

1. **For jobs without history + future scheduled time:** EXCLUDE (not due yet)
2. **For jobs without history + past scheduled time:** REPORT AS OVERDUE (should fail!)
3. **For jobs with history + failed status:** REPORT AS FAILED ✓
4. **For jobs with history + succeeded status:** Check runtime ✓

### Proposed Logic

```perl
# In JobSubsystem::Job::check() method for failed-jobs mode:

if ($self->mode =~ /server::jobs::failed/) {
    if (! defined $self->{lastrundatetime}) {
        # No execution history
        if (! defined $self->{nextrundatetime}) {
            # No schedule info - exclude
            return;
        } elsif ($self->{nextrundatetime} < CURRENT_TIME) {
            # Scheduled time is in the past - OVERDUE!
            $self->add_critical(sprintf "%s is overdue! Scheduled for %s, never executed",
                $self->{name}, $self->{nextrundatetime});
        } else {
            # Scheduled time is in the future - not due yet, exclude
            return;
        }
    } elsif ($self->{lastrunstatus} eq "Failed") {
        # Has history and failed
        $self->add_critical(sprintf "%s failed at %s: %s",
            $self->{name}, $self->{lastrundatetime}, $self->{lastrunstatusmessage});
    } elsif ($self->{lastrunstatus} eq "Retry" || $self->{lastrunstatus} eq "Canceled") {
        # Has history but had issues
        $self->add_warning(sprintf "%s %s: %s",
            $self->{name}, $self->{lastrunstatus}, $self->{lastrunstatusmessage});
    } else {
        # Has history and succeeded - check runtime
        # ... existing logic ...
    }
}
```

### Questions for Decision

1. **Should overdue jobs (past schedule, no history) be CRITICAL or WARNING?**
   - CRITICAL: Job failed to run when it should have
   - WARNING: Job is overdue but may still run

2. **Should we exclude jobs with future schedules?**
   - YES: Only check jobs that are overdue or have already run
   - NO: Include all jobs and let user decide

3. **Should the lookback filter apply to overdue jobs?**
   - YES: Only check jobs within lookback window
   - NO: Overdue jobs should always be reported

4. **What about the MIN() bug in the NextRunDateTime query?**
   - Fix it separately or as part of this change?
