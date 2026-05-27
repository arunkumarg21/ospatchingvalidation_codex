USE [msdb];
GO

/*
    Update these values before running:
    1. @ScriptRoot must point to the deployed Phase1_RunID_Framework folder.
    2. @PatchBatchId should identify the patch window, for example MAY2026-PROD-WAVE1.
    3. Create one PRE job and one POST job, or convert the commands into job tokens if preferred.
*/

DECLARE
    @ScriptRoot nvarchar(4000) = N'E:\OS_Patching_Validation\Phase1_RunID_Framework',
    @PatchBatchId nvarchar(100) = N'MAY2026-PROD-WAVE1',
    @ReturnCode int = 0,
    @jobId binary(16),
    @preCommand nvarchar(max),
    @postCommand nvarchar(max),
    @reportCommand nvarchar(max);

SET @preCommand = N'PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "' + @ScriptRoot + N'\Scripts\Invoke-Validation.ps1" -Stage PRE -PatchBatchId "' + @PatchBatchId + N'" -ConfigPath "' + @ScriptRoot + N'\settings.json"';
SET @postCommand = N'PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "' + @ScriptRoot + N'\Scripts\Invoke-Validation.ps1" -Stage POST -PatchBatchId "' + @PatchBatchId + N'" -ConfigPath "' + @ScriptRoot + N'\settings.json"';
SET @reportCommand = N'
EXEC dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId = ''' + @PatchBatchId + N''',
    @SendMail = 1,
    @MailProfile = ''Production Database Mail'',
    @Recipients = ''dba-team@company.com'';';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = N'DBA Validation' AND category_class = 1)
BEGIN
    EXEC @ReturnCode = msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'DBA Validation';
END;

EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name = N'SQL_health_checks_PRE_RunID',
    @enabled = 0,
    @description = N'Run SQL patch PRE validation using RunID framework.',
    @category_name = N'DBA Validation',
    @owner_login_name = N'sa',
    @job_id = @jobId OUTPUT;

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_name = N'Run PRE validation',
    @subsystem = N'CmdExec',
    @command = @preCommand,
    @on_success_action = 1,
    @on_fail_action = 2;

EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';

SET @jobId = NULL;

EXEC @ReturnCode = msdb.dbo.sp_add_job
    @job_name = N'SQL_health_checks_POST_RunID',
    @enabled = 0,
    @description = N'Run SQL patch POST validation using RunID framework and send comparison report.',
    @category_name = N'DBA Validation',
    @owner_login_name = N'sa',
    @job_id = @jobId OUTPUT;

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_name = N'Run POST validation',
    @subsystem = N'CmdExec',
    @command = @postCommand,
    @on_success_action = 3,
    @on_fail_action = 2;

EXEC @ReturnCode = msdb.dbo.sp_add_jobstep
    @job_id = @jobId,
    @step_name = N'Send RunID patch validation report',
    @subsystem = N'TSQL',
    @database_name = N'AdminDB',
    @command = @reportCommand,
    @on_success_action = 1,
    @on_fail_action = 2;

EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
GO
