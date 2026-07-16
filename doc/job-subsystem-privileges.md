# Job subsystem: required privileges (and the two optional enhancements)

`check-mssql-health --mode create-monitoring-user` grants the monitoring user,
in `msdb`, SELECT on:

- `sysjobs`
- `sysjobschedules`
- `sysjobhistory`
- `sysjobactivity`  *(enables running-detection)*
- `sysschedules`    *(enables overdue-never-run)*

The **base** failed-jobs query needs only the first three; the last two power
two enhancements. As of the current version, `create-monitoring-user` grants all
five, so a freshly created monitoring user gets the enhancements by default.
Users created by **older** versions of the tool (or hardened setups where the
last two are revoked) still work — the query is permission-aware and simply
omits whatever it cannot read. The two enhancement objects are:

| Enhancement | Needs SELECT on | What you lose without it |
|-------------|-----------------|--------------------------|
| **Running-detection** — live status + elapsed time of a run that is executing *right now* (including a first-ever run), and runtime warn/crit *while the job is still running* | `msdb.dbo.sysjobactivity` | A currently-running job is reported from its previous finished run (or as `DidNeverRun` on a first run). Long-runtime alerts fire only *after* the job finishes. |
| **Overdue-never-run** — WARNING when a job that never ran is past its scheduled start | `msdb.dbo.sysschedules` | A never-run job with a past schedule is reported OK (`did never run`) instead of overdue. |

## How the plugin handles missing privileges

The query is **permission-aware**. On each run it first probes, with a call that
needs no special rights:

```sql
SELECT HAS_PERMS_BY_NAME('msdb.dbo.sysjobactivity', 'OBJECT', 'SELECT'),
       HAS_PERMS_BY_NAME('msdb.dbo.sysschedules',   'OBJECT', 'SELECT');
```

and then assembles the job query with the `sysjobactivity` / `sysschedules`
joins spliced in **only where the grant exists**. Consequences:

- With the default monitoring grants → the plain three-table query runs.
  **No `SELECT permission denied` errors**, and behaviour matches earlier
  versions of the plugin (which never read these objects). The core verdicts —
  Failed → CRITICAL, Succeeded/Canceled/Retry, runtime thresholds on finished
  jobs, timezone-safe lookback aging — are all unaffected.
- With the extra grants → the enhancements light up automatically. No flags to
  set; the plugin adapts per instance.

There is **one row template** in the code; the two joins are optional fragments,
so there is no risk of two hand-maintained queries drifting apart.

> The running-detection join no longer reads `msdb.dbo.syssessions`. The current
> Agent session is found as `MAX(session_id)` within `sysjobactivity` itself, so
> enabling running-detection needs a grant on `sysjobactivity` only.

## Enabling / disabling the enhancements

`create-monitoring-user` grants both enhancement objects by default. For a user
created by an older version, grant them manually:

```sql
USE msdb;
GRANT SELECT ON sysjobactivity TO <monitoring_user>;  -- running-detection
GRANT SELECT ON sysschedules   TO <monitoring_user>;  -- overdue-never-run
```

To keep a stricter least-privilege footprint, `REVOKE` either object; the query
degrades to the base behavior for whatever is revoked.

Each enhancement is gated on its own object. In the
two common configurations (both granted, or neither) behaviour is
self-consistent. In the mixed case where only `sysschedules` is granted, a job
executing for the very first time past its scheduled start can be briefly
mislabeled *overdue* while it actually runs, because without `sysjobactivity`
the plugin cannot tell it is currently running; grant `sysjobactivity` too to
avoid that edge case.

See `doc/job-subsystem-timezones.md` for how the timestamps these objects return
are interpreted.
