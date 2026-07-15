## adding debug code

### extending the SQL with one attribute for the original run_status

I added another column `ORIGUSTA` which contains the original `[sJOBH].[run_status]`:
```
                CASE [sJOBH].[run_status]
                    WHEN 0 THEN 'Failed'
                    WHEN 1 THEN 'Succeeded'
                    WHEN 2 THEN 'Retry'
                    WHEN 3 THEN 'Canceled'
                    WHEN 4 THEN 'Running' -- In Progress
                    ELSE 'DidNeverRun'
                END AS [LastRunStatus],
                [sJOBH].[run_status] AS ORIGRUSTA,
```

### debug output, sql response with the extra attribute

When i run the plugin with  -vvvvvvvvvvvvvvvvvv, then it dumps the records from the database sql command:

Attribute #7 is LastRunStatus
Attribute #8 is ORIGRUSTA

So here we have:
* Failed - 0
* Succeeded - 1
* DidNeverRun - undev

```
  [
    '35DE8E23-615A-4660-9887-F9FAB9E78B31',
    'IndexOptimize - USER_DATABASES',
    'Jul 13 2026 11:53AM',
    833,
    6671,
    'Jul 12 2026 10:00PM',
    'Failed',
    0,
    '1:51:11',
    'The job failed.  The Job was invoked by Schedule 30 (IndexOptimize - USER_DATABASES).  The last step to run was step 1 (IndexOptimize - USER_DATABASES).',
    'Jul 13 2026 10:00PM'
  ],
  [
    '325AE435-49FF-4354-B961-2D4F4EA08D31',
    'syspolicy_purge_history',
    'Jul 13 2026 11:53AM',
    593,
    1,
    'Jul 13 2026 02:00AM',
    'Succeeded',
    1,
    '0:00:01',
    'The job succeeded.  The Job was invoked by Schedule 8 (syspolicy_purge_history_schedule).  The last step to run was step 3 (Erase Phantom System Health Records.).',
    'Jul 14 2026 02:00AM'
  ],
  [
    '6D53DD32-0538-45FE-A494-47695BDAE522',
    'VulnerabilityManagement',
    'Jul 13 2026 11:53AM',
    undef,
    undef,
    undef,
    'DidNeverRun',
    undef,
    undef,
    undef,
    'Jul  1 2026 02:00AM'
  ]
```

### SQL commands suggested for debugging and their results

#### Query 1
```
SELECT
    job_id,
    name,
    enabled,
    description,
    date_created,
    date_modified,
    category_id,
    owner_sid
FROM msdb.dbo.sysjobs
WHERE name IN (
    N'IndexOptimize - USER_DATABASES',
    N'StatisticsUpdate',
    N'syspolicy_purge_history',
    N'VulnerabilityManagement'
)
ORDER BY name
```

#### Response 1
```
job_id  name    enabled description     date_created    date_modified   category_id     owner_sid
35DE8E23-615A-4660-9887-F9FAB9E78B31    IndexOptimize - USER_DATABASES  1       Source: https://ola.hallengren.com      Apr  1 2022 11:05AM     Jul  6 2026 07:28AM     3       01
D65576A1-65B0-4C4C-A4A1-4F36FD2CD84A    StatisticsUpdate        1       No description available.       Jul 21 2025 03:33PM     Jul  5 2026 08:42AM     3       01
325AE435-49FF-4354-B961-2D4F4EA08D31    syspolicy_purge_history 1       No description available.       Mar 31 2022 09:37PM     May 21 2026 08:31PM     0       01
6D53DD32-0538-45FE-A494-47695BDAE522    VulnerabilityManagement 0       Führt monatlich alle regelmäßigen Jobs für das Schwachstellenmanagement aus.    May 24 2022 09:26AM     May 24 2022 09:26AM   0       01
```

#### Query 2
```
SELECT
    j.name AS JobName,
    j.job_id,
    js.schedule_id,
    js.next_run_date,
    js.next_run_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js
    ON j.job_id = js.job_id
WHERE j.name IN (
    N'IndexOptimize - USER_DATABASES',
    N'StatisticsUpdate',
    N'syspolicy_purge_history',
    N'VulnerabilityManagement'
)
ORDER BY j.name, js.schedule_id;
```

#### Response 2
```
JobName job_id  schedule_id     next_run_date   next_run_time
IndexOptimize - USER_DATABASES  35DE8E23-615A-4660-9887-F9FAB9E78B31    30      20260713        220000
StatisticsUpdate        D65576A1-65B0-4C4C-A4A1-4F36FD2CD84A    43      20260718        200000
syspolicy_purge_history 325AE435-49FF-4354-B961-2D4F4EA08D31    8       20260714        20000
VulnerabilityManagement 6D53DD32-0538-45FE-A494-47695BDAE522    24      20260701        20000
```

#### Query 3
```
SELECT
    job_id,
    step_id,
    instance_id,
    run_date,
    run_time,
    run_status,
    run_duration,
    message
FROM msdb.dbo.sysjobhistory
WHERE job_id IN (
    SELECT job_id
    FROM msdb.dbo.sysjobs
    WHERE name IN (
        N'IndexOptimize - USER_DATABASES',
        N'StatisticsUpdate',
        N'syspolicy_purge_history',
        N'VulnerabilityManagement'
    )
)
ORDER BY job_id, instance_id DESC, step_id DESC
```

#### Response 3
```
job_id  step_id instance_id     run_date        run_time        run_status      run_duration    message
325AE435-49FF-4354-B961-2D4F4EA08D31    0       662303  20260713        20000   1       1       The job succeeded.  The Job was invoked by Schedule 8 (syspolicy_purge_history_schedule).  The last step to run was step 3 (Erase Phantom System Health Records.).
325AE435-49FF-4354-B961-2D4F4EA08D31    3       662302  20260713        20001   1       0       Executed as user: ARSCH\gSRVS00008$. The step did not generate any output.  Process Exit Code 0.  The step succeeded.
325AE435-49FF-4354-B961-2D4F4EA08D31    2       662297  20260713        20000   1       1       Executed as user: ARSCH\gSRVS00008$. The step succeeded.
325AE435-49FF-4354-B961-2D4F4EA08D31    1       662292  20260713        20000   1       0       Executed as user: ARSCH\gSRVS00008$. The step succeeded.
325AE435-49FF-4354-B961-2D4F4EA08D31    0       661496  20260712        20000   1       4       The job succeeded.  The Job was invoked by Schedule 8 (syspolicy_purge_history_schedule).  The last step to run was step 3 (Erase Phantom System Health Records.).
325AE435-49FF-4354-B961-2D4F4EA08D31    3       661495  20260712        20000   1       4       Executed as user: ARSCH\gSRVS00008$. The step did not generate any output.  Process Exit Code 0.  The step succeeded.
325AE435-49FF-4354-B961-2D4F4EA08D31    2       661487  20260712        20000   1       0       Executed as user: ARSCH\gSRVS00008$. The step succeeded.
325AE435-49FF-4354-B961-2D4F4EA08D31    1       661485  20260712        20000   1       0       Executed as user: ARSCH\gSRVS00008$. The step succeeded.
D65576A1-65B0-4C4C-A4A1-4F36FD2CD84A    0       661301  20260711        200000  1       752     The job succeeded.  The Job was invoked by Schedule 43 (Weekly).  The last step to run was step 1 (StatsUpdate).
D65576A1-65B0-4C4C-A4A1-4F36FD2CD84A    1       661300  20260711        200000  1       752     Executed as user: ARSCH\gSRVS00008$. ...50000)  Server: VRZ1418SQLI2\I2 [SQLSTATE 01000] (Message 50000)  Version: 15.0.4470.1 [SQLSTATE 01000] (Message 50000)  Edition: Enterprise Edition: Core-based Licensing (64-bit) [SQLSTATE 01000] (Message 50000)  Platform: Windows [SQLSTATE 01000] (Message 50000)  Contained availability group connection: No [SQLSTATE 01000] (Message 50000)  Procedure: [master].[dbo].[IndexOptimize] [SQLSTATE 01000] (Message 50000)  Parameters: @Databases = 'USER_DATABASES', @FragmentationLow = NULL, @FragmentationMedium = NULL, @FragmentationHigh = NULL, @FragmentationLevel1 = 5, @FragmentationLevel2 = 30, @MinNumberOfPages = 100, @MaxNumberOfPages = NULL, @SortInTempdb = 'N', @MaxDOP = 2, @FillFactor = NULL, @PadIndex = NULL, @DataCompression = NULL, @WaitAtLowPriorityMaxDuration = 60, @WaitAtLowPriorityAbortAfterWait = 'SELF', @Resumable = 'Y', @LOBCompaction = 'Y', @UpdateStatistics = 'ALL', @OnlyModifiedStatistics = 'Y', @StatisticsModificationLevel = NULL, @StatisticsSample = NULL, @StatisticsPersistSample = NULL, @StatisticsResample = 'N', @PartitionLevel = 'Y', @MSShippedObjects = 'N', @Indexes = NULL, @TimeLimit = 7200, @Delay = NULL, @AvailabilityGroups = NULL, @LockTimeout = NULL, @LockMessageSeverity = 16, @StringDelimiter = ',', @DatabaseOrder = NULL, @DatabasesInParallel = 'N', @ExecuteAsUser = NULL, @LogToTable = 'Y', @Execute = 'Y' [SQLSTATE 01000] (Message 50000)  Version: 2026-06-21 12:55:55 [SQLSTATE 01000] (Message 50000)  Source: https://ola.hallengren.com [SQLSTATE 01000] (Message 50000)         [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:00 [SQLSTATE 01000] (Message 50000)  Database: [AACM] [SQLSTATE 01000] (Message 50000)  State: ONLINE [SQLSTATE 01000] (Message 50000)  Standby: No [SQLSTATE 01000] (Message 50000)  Updateability: READ_WRITE [SQLSTATE 01000] (Message 50000)  User access: MULTI_USER [SQLSTATE 01000] (Message 50000)  Recovery model: FULL [SQLSTATE 01000] (Message 50000)         [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)  Database context: [AACM] [SQLSTATE 01000] (Message 50000)  Command: UPDATE STATISTICS [dbo].[Bestellungen] [_WA_Sys_00000001_565FA31D] WITH MAXDOP = 2 [SQLSTATE 01000] (Message 50000)  Comment: ObjectType: Table, StatisticsType: Column, Incremental: No, RowCount: 109870, ModificationCounter: 1542287 [SQLSTATE 01000] (Message 50000)  Outcome: Succeeded [SQLSTATE 01000] (Message 50000)  Duration: 00:00:00 [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)       [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)  Database context: [AACM] [SQLSTATE 01000] (Message 50000)  Command: UPDATE STATISTICS [dbo].[Bestellungen] [_WA_Sys_00000002_565FA31D] WITH MAXDOP = 2 [SQLSTATE 01000] (Message 50000)  Comment: ObjectType: Table, StatisticsType: Column, Incremental: No, RowCount: 109870, ModificationCounter: 1542287 [SQLSTATE 01000] (Message 50000)  Outcome: Succeeded [SQLSTATE 01000] (Message 50000)  Duration: 00:00:00 [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)     [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)  Database context: [AACM] [SQLSTATE 01000] (Message 50000)  Command: UPDATE STATISTICS [dbo].[Bestellungen] [_WA_Sys_00000005_565FA31D] WITH MAXDOP = 2 [SQLSTATE 01000] (Message 50000)  Comment: ObjectType: Table, StatisticsType: Column, Incremental: No, RowCount: 109870, ModificationCounter: 1542287 [SQLSTATE 01000] (Message 50000)  Outcome: Succeeded [SQLSTATE 01000] (Message 50000)  Duration: 00:00:00 [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)       [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-11 20:00:01 [SQLSTATE 01000] (Message 50000)  Database context: [AACM] [SQLSTATE 01000]...  The step succeeded.
35DE8E23-615A-4660-9887-F9FAB9E78B31    0       662226  20260712        220000  0       15111   The job failed.  The Job was invoked by Schedule 30 (IndexOptimize - USER_DATABASES).  The last step to run was step 1 (IndexOptimize - USER_DATABASES).
35DE8E23-615A-4660-9887-F9FAB9E78B31    1       662225  20260712        220000  0       15111   Executed as user: ARSCH\gSRVS00008$. ...ge 50000)  Server: VRZ1418SQLI2\I2 [SQLSTATE 01000] (Message 50000)  Version: 15.0.4470.1 [SQLSTATE 01000] (Message 50000)  Edition: Enterprise Edition: Core-based Licensing (64-bit) [SQLSTATE 01000] (Message 50000)  Platform: Windows [SQLSTATE 01000] (Message 50000)  Contained availability group connection: No [SQLSTATE 01000] (Message 50000)  Procedure: [master].[dbo].[IndexOptimize] [SQLSTATE 01000] (Message 50000)  Parameters: @Databases = 'USER_DATABASES', @FragmentationLow = NULL, @FragmentationMedium = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE', @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE', @FragmentationLevel1 = 5, @FragmentationLevel2 = 30, @MinNumberOfPages = 100, @MaxNumberOfPages = NULL, @SortInTempdb = 'N', @MaxDOP = 2, @FillFactor = NULL, @PadIndex = NULL, @DataCompression = NULL, @WaitAtLowPriorityMaxDuration = 60, @WaitAtLowPriorityAbortAfterWait = 'SELF', @Resumable = 'Y', @LOBCompaction = 'Y', @UpdateStatistics = NULL, @OnlyModifiedStatistics = 'N', @StatisticsModificationLevel = NULL, @StatisticsSample = NULL, @StatisticsPersistSample = NULL, @StatisticsResample = 'N', @PartitionLevel = 'Y', @MSShippedObjects = 'N', @Indexes = NULL, @TimeLimit = 10800, @Delay = NULL, @AvailabilityGroups = NULL, @LockTimeout = NULL, @LockMessageSeverity = 16, @StringDelimiter = ',', @DatabaseOrder = NULL, @DatabasesInParallel = 'N', @ExecuteAsUser = NULL, @LogToTable = 'Y', @Execute = 'Y' [SQLSTATE 01000] (Message 50000)  Version: 2026-06-21 12:55:55 [SQLSTATE 01000] (Message 50000)  Source: https://ola.hallengren.com [SQLSTATE 01000] (Message 50000)     [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-12 22:00:01 [SQLSTATE 01000] (Message 50000)  Database: [AACM] [SQLSTATE 01000] (Message 50000)  State: ONLINE [SQLSTATE 01000] (Message 50000)  Standby: No [SQLSTATE 01000] (Message 50000)  Updateability: READ_WRITE [SQLSTATE 01000] (Message 50000)  User access: MULTI_USER [SQLSTATE 01000] (Message 50000)  Recovery model: FULL [SQLSTATE 01000] (Message 50000)      [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-12 22:00:01 [SQLSTATE 01000] (Message 50000)  Database context: [AACM] [SQLSTATE 01000] (Message 50000)  Command: ALTER INDEX [PK__Standort__C6555721BBFA955E] ON [dbo].[Standorte] REBUILD WITH (SORT_IN_TEMPDB = OFF, ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 60, ABORT_AFTER_WAIT = SELF)), MAXDOP = 2, RESUMABLE = ON, MAX_DURATION = 180) [SQLSTATE 01000] (Message 50000)  Comment: ObjectType: Table, IndexType: Clustered, ImageText: No, NewLOB: No, FileStream: No, HasClusteredColumnstore: No, HasNonClusteredColumnstore: No, Computed: No, Timestamp: No, HasFilter: No, AllowPageLocks: Yes, PageCount: 827, Fragmentation: 60.0967 [SQLSTATE 01000] (Message 50000)  Outcome: Succeeded [SQLSTATE 01000] (Message 50000)  Duration: 00:00:00 [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-12 22:00:01 [SQLSTATE 01000] (Message 50000)    [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-12 22:00:01 [SQLSTATE 01000] (Message 50000)  Database: [ABM_Infoscreen_Backend] [SQLSTATE 01000] (Message 50000)  State: ONLINE [SQLSTATE 01000] (Message 50000)  Standby: No [SQLSTATE 01000] (Message 50000)  Updateability: READ_WRITE [SQLSTATE 01000] (Message 50000)  User access: MULTI_USER [SQLSTATE 01000] (Message 50000)  Recovery model: SIMPLE [SQLSTATE 01000] (Message 50000)           [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-12 22:00:03 [SQLSTATE 01000] (Message 50000)  Database: [ABM_Infoscreen_Backend_Test] [SQLSTATE 01000] (Message 50000)  State: ONLINE [SQLSTATE 01000] (Message 50000)  Standby: No [SQLSTATE 01000] (Message 50000)  Updateability: READ_WRITE [SQLSTATE 01000] (Message 50000)  User access: MULTI_USER [SQLSTATE 01000] (Message 50000)  Recovery model: SIMPLE [SQLSTATE 01000] (Message 50000)        [SQLSTATE 01000] (Message 50000)  Date and time: 2026-07-12 22:00:03 [SQLSTATE 01000] (Message 5...  The step failed.

```

#### Query 4

```
SELECT
    j.name AS JobName,
    j.job_id,
    js.schedule_id,
    js.next_run_date,
    js.next_run_time,
    ss.name AS ScheduleName,
    ss.enabled,
    ss.freq_type,
    ss.freq_interval,
    ss.active_start_date,
    ss.active_start_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js
    ON j.job_id = js.job_id
JOIN msdb.dbo.sysschedules ss
    ON js.schedule_id = ss.schedule_id
WHERE j.name IN (
    N'IndexOptimize - USER_DATABASES',
    N'StatisticsUpdate',
    N'syspolicy_purge_history',
    N'VulnerabilityManagement'
)
ORDER BY j.name, js.schedule_id
```

#### Response 4

```
JobName job_id  schedule_id     next_run_date   next_run_time   ScheduleName    enabled freq_type       freq_interval   active_start_date       active_start_time
IndexOptimize - USER_DATABASES  35DE8E23-615A-4660-9887-F9FAB9E78B31    30      20260713        220000  IndexOptimize - USER_DATABASES  1       8       63      20220601        220000
StatisticsUpdate        D65576A1-65B0-4C4C-A4A1-4F36FD2CD84A    43      20260718        200000  Weekly  1       8       64      20250516        200000
syspolicy_purge_history 325AE435-49FF-4354-B961-2D4F4EA08D31    8       20260714        20000   syspolicy_purge_history_schedule        1       4       1       20080101        20000
VulnerabilityManagement 6D53DD32-0538-45FE-A494-47695BDAE522    24      20260701        20000   UpdateSchwachstellenstatistik   1       16      1       20130315        20000
```




