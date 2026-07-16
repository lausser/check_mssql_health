-- Integration-test scenario jobs for the failed-jobs mode.
-- Executed against msdb. All jobs are prefixed JobTest_ so cleanup is a
-- single sweep. Durations are chosen so the whole suite runs in ~7 minutes.
USE msdb;
GO

-- FailQuick: fails immediately (run_status 0 -> Failed -> CRITICAL).
EXEC dbo.sp_add_job @job_name = N'JobTest_FailQuick', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_FailQuick', @step_name = N'fail',
     @subsystem = N'TSQL', @command = N'RAISERROR(N''test failure'', 11, 1) WITH NOWAIT',
     @database_name = N'master', @retry_attempts = 0;
EXEC dbo.sp_add_jobserver @job_name = N'JobTest_FailQuick', @server_name = N'(LOCAL)';
GO

-- SucceedQuick: succeeds in ~0s (Succeeded -> runtime path, well under threshold).
EXEC dbo.sp_add_job @job_name = N'JobTest_SucceedQuick', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_SucceedQuick', @step_name = N'ok',
     @subsystem = N'TSQL', @command = N'SELECT 1', @database_name = N'master';
EXEC dbo.sp_add_jobserver @job_name = N'JobTest_SucceedQuick', @server_name = N'(LOCAL)';
GO

-- SucceedSlow: succeeds after ~80s (Succeeded but over the 60s warning
-- threshold -> WARNING on the finished-job runtime path).
EXEC dbo.sp_add_job @job_name = N'JobTest_SucceedSlow', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_SucceedSlow', @step_name = N'wait',
     @subsystem = N'TSQL', @command = N'WAITFOR DELAY ''00:01:20''', @database_name = N'master';
EXEC dbo.sp_add_jobserver @job_name = N'JobTest_SucceedSlow', @server_name = N'(LOCAL)';
GO

-- Runner: runs ~6 minutes. Used to probe the running-job runtime thresholds at
-- <60s (OK), >60s (WARNING), >300s (CRITICAL), then finishes Succeeded, then is
-- restarted to prove live activity wins over the just-written history row.
EXEC dbo.sp_add_job @job_name = N'JobTest_Runner', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_Runner', @step_name = N'wait',
     @subsystem = N'TSQL', @command = N'WAITFOR DELAY ''00:06:00''', @database_name = N'master';
EXEC dbo.sp_add_jobserver @job_name = N'JobTest_Runner', @server_name = N'(LOCAL)';
GO

-- CancelMe: long runner that the test stops mid-flight (Canceled -> WARNING).
EXEC dbo.sp_add_job @job_name = N'JobTest_CancelMe', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_CancelMe', @step_name = N'wait',
     @subsystem = N'TSQL', @command = N'WAITFOR DELAY ''00:10:00''', @database_name = N'master';
EXEC dbo.sp_add_jobserver @job_name = N'JobTest_CancelMe', @server_name = N'(LOCAL)';
GO

-- NeverRunFuture: never started, schedule far in the future -> OK.
EXEC dbo.sp_add_job @job_name = N'JobTest_NeverRunFuture', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_NeverRunFuture', @step_name = N'noop',
     @subsystem = N'TSQL', @command = N'SELECT 1', @database_name = N'master';
EXEC dbo.sp_add_schedule @schedule_name = N'JobTest_NeverRunFuture_Sched', @enabled = 1,
     @freq_type = 1, @active_start_date = 20990101, @active_start_time = 0;
EXEC dbo.sp_attach_schedule @job_name = N'JobTest_NeverRunFuture',
     @schedule_name = N'JobTest_NeverRunFuture_Sched';
GO

-- NeverRunPast: never started, daily schedule that started in the past ->
-- overdue -> WARNING.
EXEC dbo.sp_add_job @job_name = N'JobTest_NeverRunPast', @enabled = 1;
EXEC dbo.sp_add_jobstep @job_name = N'JobTest_NeverRunPast', @step_name = N'noop',
     @subsystem = N'TSQL', @command = N'SELECT 1', @database_name = N'master';
EXEC dbo.sp_add_schedule @schedule_name = N'JobTest_NeverRunPast_Sched', @enabled = 1,
     @freq_type = 4, @freq_interval = 1, @active_start_date = 20200101, @active_start_time = 0;
EXEC dbo.sp_attach_schedule @job_name = N'JobTest_NeverRunPast',
     @schedule_name = N'JobTest_NeverRunPast_Sched';
GO
