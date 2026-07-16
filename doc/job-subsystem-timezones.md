# Job subsystem: dates, times and timezones

The `server::jobs::*` modes read timing information out of the SQL Server Agent
tables in `msdb`. Those tables store time in several different, inconsistent
formats, and none of them carries a timezone. This document explains what the
formats are, which ones are safe to compare, and how `check_mssql_health`
avoids the classic "the monitoring host is in a different timezone than the
database" trap.

All examples below are real output from a live SQL Server 2022 instance. In this
setup the **database server runs in UTC** and the **monitoring host runs in
CEST (UTC+2)** — a deliberate mismatch, because that is exactly the situation
that goes wrong if timezones are handled naively.

```
host:      2026-07-16 12:46:55 CEST (+0200)
container: 2026-07-16 10:46:55 UTC  (+0000)
```

---

## 1. What kinds of time values come back from the query

There are only two fundamentally different things in the result set:

| Kind | Meaning | Timezone-sensitive? |
|------|---------|---------------------|
| **Point in time** ("wall clock") | *when* something happened / will happen | **Yes** — it is the server's local wall-clock reading, with no offset attached |
| **Duration** | *how long* something took / has been running | **No** — a count of seconds, independent of any clock |

The whole trick to getting timezones right is: **durations are safe, points in
time are not**. Everything below is just a consequence of that.

---

## 2. Which columns the SQL statement reads, and in what raw format

The base types in `msdb` are a museum of formats. Confirmed live:

```
sysjobhistory.run_date              | int
sysjobhistory.run_time              | int
sysjobhistory.run_duration          | int
sysjobactivity.start_execution_date | datetime
sysjobschedules.next_run_date       | int
sysschedules.active_start_date      | int
sysschedules.active_start_time      | int
```

### 2a. Integer date + integer time (the "YYYYMMDD / HHMMSS" encoding)

`sysjobhistory`, `sysjobschedules` and `sysschedules` do **not** use a datetime
type. They split a wall-clock moment into two integers:

- date as `YYYYMMDD` — e.g. `20260716`
- time as `HHMMSS` with leading zeros stripped — e.g. `104700` means `10:47:00`,
  and `500` would mean `00:05:00`

Real rows from a job that runs every minute:

```
name           | run_date | run_time | run_duration | reconstructed_datetime
EveryMinuteJob  | 20260716 | 104700   | 0            | 2026-07-16 10:47:00
EveryMinuteJob  | 20260716 | 104600   | 0            | 2026-07-16 10:46:00
EveryMinuteJob  | 20260716 | 104500   | 0            | 2026-07-16 10:45:00
```

The SQL statement reassembles the two integers into a real `DATETIME` and then
formats it as an ISO string with `CONVERT(..., 120)` (see §4). This is a **point
in time** in the server's local zone.

### 2b. `datetime` columns

`sysjobactivity.start_execution_date` / `stop_execution_date` are real
`datetime` values — the start/stop of the *current or most recent* run in the
active Agent session. Still a **point in time** in the server's local zone; still
no offset attached.

```
name           | start_execution_date | stop_execution_date
EveryMinuteJob  | 2026-07-16 10:47:00  | 2026-07-16 10:47:00
```

### 2c. `run_duration` — a duration, but encoded as an integer, *not* seconds

`run_duration` is an `int`, but it is **not** a number of seconds. It is
`HHMMSS` packed into a decimal integer, exactly like `run_time`. `122` is *one
minute and twenty-two seconds*, not 122 seconds. The statement decodes it to
real seconds:

```
run_duration | seconds
122          | 82        (00:01:22)
600          | 360       (00:06:00)
10230        | 3750      (01:02:30)
35959        | 14399     (03:59:59)
```

The decode is `floor(run_duration/10000)*3600 + tens_of_minutes*60 + seconds`.
(The division `run_duration/10000` is integer division in T-SQL, so the
surrounding `round(...)` is a no-op safety net, not a real rounding step.)

---

## 3. Which values are epoch-like / safe, and which must be normalized

**Safe — durations, already timezone-independent:**

- `LastRunDurationSeconds` for a *finished* job = the decoded `run_duration`
  (§2c). A pure elapsed-seconds count.
- `LastRunDurationSeconds` for a *running* job =
  `DATEDIFF(SECOND, start_execution_date, CURRENT_TIMESTAMP)` — computed
  **inside the server**, so both operands are in the same clock and the result
  is correct seconds regardless of anyone's timezone.

These feed the runtime thresholds (`--warning`/`--critical`, default 60/300 s)
directly. No normalization needed.

**Careful — points in time, wall clock in the server's zone, no offset:**

- `LastRunDateTime` (from `run_date`+`run_time`, or from `start_execution_date`
  for a running job)
- `NextRunDateTime` (from `next_run_date`+`next_run_time`, or the schedule's
  `active_start_date`+`active_start_time` fallback for never-run jobs)
- `Now` (`CURRENT_TIMESTAMP`)

These are the dangerous ones. The string `2026-07-16 10:47:00` tells you the
server's wall clock said 10:47 — but **not** which zone that is. The same job
row looks identical whether the server is in Reykjavík or Tokyo. You cannot turn
such a string into a real absolute epoch without knowing the server's zone,
which the row does not tell you.

The critical insight: **we never need the absolute epoch.** We only ever ask
questions like *"did this finish within the last N minutes?"* or *"is the next
run overdue?"* — i.e. differences between two of these server wall-clock values.
As long as every one of them is parsed in the *same* fixed frame, the unknown
server offset cancels out of the subtraction.

---

## 4. How the check host's clock is brought in sync with the database's clock

It isn't — and that is the point. Instead of trying to reconcile the two clocks,
the plugin **stops using the host clock for job timing entirely** and measures
everything against the server's own clock.

The SQL statement selects the server's current time as a column:

```sql
CONVERT(VARCHAR(30), CURRENT_TIMESTAMP, 120) AS [Now]  -- e.g. 2026-07-16 10:50:21
```

Every age/overdue decision compares a server timestamp against **this `Now`**,
not against the host's `time()`:

- *in scope?* `finished_time + lookback ≥ now_epoch()`
- *overdue?* `next_run_epoch ≤ now_epoch()`

where `now_epoch()` parses that `Now` column. Because `finished_time`,
`next_run_epoch` and `now_epoch()` are all server wall-clock values parsed the
same way, the server's timezone offset is identical on both sides of every
comparison and disappears. A host in CEST, UTC or JST all compute the same
answer — which matters because one monitoring host commonly checks database
servers all over the world.

`Style 120` (`YYYY-MM-DD HH:MM:SS`) is used everywhere so the strings are
locale-independent and unambiguous, instead of the driver's default format
(which can be `Mon DD YYYY hh:mmAM` and varies by language setting).

The host clock (`time()`) is used **only** as a fallback when the `Now` column
is somehow absent (e.g. in the pure-Perl unit tests, which construct rows by
hand and stay internally consistent).

> Note: `SYSDATETIMEOFFSET()` *does* expose the server's real offset
> (`... +00:00` here). The plugin deliberately does **not** rely on it — the
> cancel-it-out approach needs no offset at all, and works even on the many
> `datetime`/`int` columns that can never carry one.

---

## 5. How the date/time strings are parsed in Perl

`iso_to_epoch()` turns a `YYYY-MM-DD HH:MM:SS` string into an epoch with
**`Time::Local::timegm`** (UTC math), never `timelocal`:

```perl
if ($dt =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/) {
  return Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1 - 1900);
}
```

Why `timegm` and not `timelocal`? Because `timelocal` would apply the *host's*
timezone and DST rules to a string that is actually in the *server's* zone.
Parsing the same server value both ways on this CEST host shows the damage
`timelocal` would do:

```
server "now" string : 2026-07-16 10:50:21   (server wall clock)
timegm(...)         : 1784199021   (parses the wall time in a fixed UTC frame)
timelocal(...)      : 1784191821   (parses the wall time as HOST-local = CEST)
difference          : 7200 s = 2 h   <-- the skew timelocal would inject
```

`timegm` is not claiming the value "is UTC". It is just a **fixed, DST-free
frame**: applied identically to every timestamp and to the server `Now`, it lets
the differences come out right no matter where the server or the host live. Using
`timelocal` would (a) reintroduce the host's offset and (b) risk an extra ±1 h
error around the host's DST switches — a value parsed near the host's spring/fall
transition can shift by an hour that has nothing to do with the server.

### Is the returned number a "real" epoch?

Only if the database server happens to run in UTC. In general it is **not** — it
is a *pseudo-epoch*: the epoch you would get *if* the server's wall-clock reading
were UTC. For a server in another zone it is off by that server's offset. Proven
live (this server is UTC, so the two coincide):

```
server local (CURRENT_TIMESTAMP): 2026-07-16 11:09:02
iso_to_epoch(CURRENT_TIMESTAMP) = 1784200142   (pseudo-epoch)
true epoch (via GETUTCDATE)      = 1784200142   (real UTC epoch)
pseudo - true                    = 0 s          (= the server's UTC offset)
```

If the same server were in `America/New_York` (offset −5 h), `iso_to_epoch()`
would return a number 5 h away from the genuine epoch of that instant — **wrong
as an absolute timestamp**, yet still perfectly usable here, because the plugin
only ever computes `timestamp − Now`, and the identical 5 h offset sits on both
sides and cancels.

So: **do not read `iso_to_epoch()`'s result as an absolute point in time.** It is
an internal, relative quantity. The only moment you would need the *true* epoch is
if you wanted to print "this happened at absolute UTC time X" or compare against a
genuine absolute epoch such as Perl's `time()`. For that you would need the
server's actual offset (`SYSDATETIMEOFFSET()` provides it). The plugin avoids that
requirement entirely by never needing the real epoch — which is also why it works
against the many `int`/`datetime` columns that can never carry an offset.

> The lone place a genuine `time()` could sneak in is the `now_epoch()` fallback
> used when the `Now` column is missing (unit tests). Mixing a real `time()` with
> pseudo-epoch timestamps would be wrong for a non-UTC server — but in live
> operation `Now` is always present (it is a constant column on every row), so the
> comparison is always pseudo-vs-pseudo and the fallback never fires.

### Summary of the pipeline

```
msdb raw            SQL normalizes                Perl parses            compared against
------------------  ----------------------------  ---------------------  ------------------
run_date+run_time   CONVERT(...,120) -> ISO str   iso_to_epoch (timegm)  now_epoch (server Now)
start_execution..   CONVERT(...,120) -> ISO str   iso_to_epoch (timegm)  now_epoch (server Now)
next_run_date+..    CONVERT(...,120) -> ISO str   iso_to_epoch (timegm)  now_epoch (server Now)
run_duration (int)  HHMMSS -> seconds (in SQL)    used as-is (integer)   thresholds (60/300 s)
elapsed of running  DATEDIFF(SECOND,..) (in SQL)  used as-is (integer)   thresholds (60/300 s)
CURRENT_TIMESTAMP   CONVERT(...,120) -> ISO str   iso_to_epoch (timegm)  = the reference clock
```

**One rule to remember:** durations are computed inside the server and used
verbatim; points in time are parsed in one fixed frame and only ever compared to
the server's own `Now`. The monitoring host's timezone never enters the job
timing math.
