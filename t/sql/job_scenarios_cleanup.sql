-- Remove all integration-test scenario jobs and their schedules.
USE msdb;
GO
DECLARE @job NVARCHAR(128);
DECLARE c CURSOR FOR SELECT name FROM dbo.sysjobs WHERE name LIKE N'JobTest_%';
OPEN c;
FETCH NEXT FROM c INTO @job;
WHILE @@FETCH_STATUS = 0
BEGIN
  BEGIN TRY EXEC dbo.sp_stop_job @job_name = @job; END TRY BEGIN CATCH END CATCH;
  EXEC dbo.sp_delete_job @job_name = @job;
  FETCH NEXT FROM c INTO @job;
END
CLOSE c;
DEALLOCATE c;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'cdc.MCM_CDB_capture')
BEGIN
  BEGIN TRY EXEC dbo.sp_stop_job @job_name = N'cdc.MCM_CDB_capture'; END TRY BEGIN CATCH END CATCH;
  EXEC dbo.sp_delete_job @job_name = N'cdc.MCM_CDB_capture';
END
GO
DECLARE @sched NVARCHAR(128);
DECLARE sc CURSOR FOR SELECT name FROM dbo.sysschedules WHERE name LIKE N'JobTest_%';
OPEN sc;
FETCH NEXT FROM sc INTO @sched;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC dbo.sp_delete_schedule @schedule_name = @sched;
  FETCH NEXT FROM sc INTO @sched;
END
CLOSE sc;
DEALLOCATE sc;
GO
