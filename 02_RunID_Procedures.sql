USE [AdminDB];
GO

CREATE OR ALTER PROCEDURE dbo.usp_ValidationRun_Start
    @PatchBatchId varchar(100),
    @Stage varchar(10),
    @ExecutedBy nvarchar(256),
    @ExecutionHost nvarchar(128),
    @TotalServers int
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.ValidationRun
    (
        PatchBatchId,
        Stage,
        ExecutedBy,
        ExecutionHost,
        TotalServers,
        OverallStatus
    )
    VALUES
    (
        @PatchBatchId,
        @Stage,
        @ExecutedBy,
        @ExecutionHost,
        @TotalServers,
        'RUNNING'
    );

    SELECT CONVERT(int, SCOPE_IDENTITY()) AS RunId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ValidationRun_Complete
    @RunId int,
    @Status varchar(30),
    @Message nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ValidationRun
    SET EndTime = sysdatetime(),
        OverallStatus = @Status,
        Message = @Message
    WHERE RunId = @RunId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ValidationResult_Insert
    @RunId int,
    @ServerName sysname,
    @ValidationType varchar(60),
    @ResultName nvarchar(256),
    @ResultKey nvarchar(512),
    @ExpectedValue nvarchar(max) = NULL,
    @ActualValue nvarchar(max) = NULL,
    @ValidationStatus varchar(20),
    @DetailsJson nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.ValidationResult
    (
        RunId,
        ServerName,
        ValidationType,
        ResultName,
        ResultKey,
        ExpectedValue,
        ActualValue,
        ValidationStatus,
        DetailsJson
    )
    VALUES
    (
        @RunId,
        @ServerName,
        @ValidationType,
        @ResultName,
        @ResultKey,
        @ExpectedValue,
        @ActualValue,
        @ValidationStatus,
        @DetailsJson
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ValidationRun_GetLatestPair
    @PatchBatchId varchar(100)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        PreRunId = (SELECT TOP (1) RunId FROM dbo.ValidationRun WHERE PatchBatchId = @PatchBatchId AND Stage = 'PRE' ORDER BY RunId DESC),
        PostRunId = (SELECT TOP (1) RunId FROM dbo.ValidationRun WHERE PatchBatchId = @PatchBatchId AND Stage = 'POST' ORDER BY RunId DESC);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ValidationResult_Compare
    @PreRunId int,
    @PostRunId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ServerName = COALESCE(postr.ServerName, prer.ServerName),
        ValidationType = COALESCE(postr.ValidationType, prer.ValidationType),
        ResultName = COALESCE(postr.ResultName, prer.ResultName),
        ResultKey = COALESCE(postr.ResultKey, prer.ResultKey),
        PreStatus = prer.ValidationStatus,
        PostStatus = postr.ValidationStatus,
        PreActualValue = prer.ActualValue,
        PostActualValue = postr.ActualValue,
        DeviationType =
            CASE
                WHEN prer.ResultId IS NULL THEN 'NEW_IN_POST'
                WHEN postr.ResultId IS NULL THEN 'MISSING_IN_POST'
                WHEN ISNULL(prer.ValidationStatus, '') <> ISNULL(postr.ValidationStatus, '') THEN 'STATUS_CHANGED'
                WHEN ISNULL(prer.ActualValue, '') <> ISNULL(postr.ActualValue, '') THEN 'VALUE_CHANGED'
                WHEN ISNULL(prer.DetailsJson, '') <> ISNULL(postr.DetailsJson, '') THEN 'DETAIL_CHANGED'
                ELSE 'MATCHED'
            END,
        PreDetailsJson = prer.DetailsJson,
        PostDetailsJson = postr.DetailsJson
    FROM
    (
        SELECT *
        FROM dbo.ValidationResult
        WHERE RunId = @PreRunId
    ) prer
    FULL OUTER JOIN
    (
        SELECT *
        FROM dbo.ValidationResult
        WHERE RunId = @PostRunId
    ) postr
        ON postr.ServerName = prer.ServerName
       AND postr.ValidationType = prer.ValidationType
       AND postr.ResultKey = prer.ResultKey;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId varchar(100) = NULL,
    @PreRunId int = NULL,
    @PostRunId int = NULL,
    @SendMail bit = 0,
    @MailProfile sysname = NULL,
    @Recipients varchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @PatchBatchId IS NOT NULL AND (@PreRunId IS NULL OR @PostRunId IS NULL)
    BEGIN
        SELECT
            @PreRunId = ISNULL(@PreRunId, (SELECT TOP (1) RunId FROM dbo.ValidationRun WHERE PatchBatchId = @PatchBatchId AND Stage = 'PRE' ORDER BY RunId DESC)),
            @PostRunId = ISNULL(@PostRunId, (SELECT TOP (1) RunId FROM dbo.ValidationRun WHERE PatchBatchId = @PatchBatchId AND Stage = 'POST' ORDER BY RunId DESC));
    END;

    IF @PreRunId IS NULL OR @PostRunId IS NULL
    BEGIN
        THROW 51000, 'PreRunId and PostRunId are required when PatchBatchId cannot resolve both runs.', 1;
    END;

    DECLARE
        @preBy nvarchar(256),
        @postBy nvarchar(256),
        @preStart datetime2(0),
        @postStart datetime2(0),
        @batch varchar(100),
        @subject nvarchar(255),
        @body nvarchar(max),
        @summaryRows nvarchar(max),
        @deviationRows nvarchar(max);

    SELECT @preBy = ExecutedBy, @preStart = StartTime, @batch = PatchBatchId
    FROM dbo.ValidationRun
    WHERE RunId = @PreRunId;

    SELECT @postBy = ExecutedBy, @postStart = StartTime, @batch = ISNULL(@batch, PatchBatchId)
    FROM dbo.ValidationRun
    WHERE RunId = @PostRunId;

    DECLARE @compare table
    (
        ServerName sysname,
        ValidationType varchar(60),
        ResultName nvarchar(256),
        ResultKey nvarchar(512),
        PreStatus varchar(20) NULL,
        PostStatus varchar(20) NULL,
        PreActualValue nvarchar(max) NULL,
        PostActualValue nvarchar(max) NULL,
        DeviationType varchar(30),
        PreDetailsJson nvarchar(max) NULL,
        PostDetailsJson nvarchar(max) NULL
    );

    INSERT @compare
    EXEC dbo.usp_ValidationResult_Compare @PreRunId = @PreRunId, @PostRunId = @PostRunId;

    SELECT @summaryRows =
    CAST((
        SELECT
            td = ValidationType, '',
            td = COUNT(1), '',
            td = SUM(CASE WHEN DeviationType = 'MATCHED' THEN 0 ELSE 1 END)
        FROM @compare
        GROUP BY ValidationType
        ORDER BY ValidationType
        FOR XML RAW('tr'), ELEMENTS
    ) AS nvarchar(max));

    SELECT @deviationRows =
    CAST((
        SELECT TOP (500)
            td = ServerName, '',
            td = ValidationType, '',
            td = ResultName, '',
            td = DeviationType, '',
            td = ISNULL(PreActualValue, ''), '',
            td = ISNULL(PostActualValue, '')
        FROM @compare
        WHERE DeviationType <> 'MATCHED'
           OR PostStatus IN ('FAIL','WARN','ERROR')
        ORDER BY ServerName, ValidationType, ResultName
        FOR XML RAW('tr'), ELEMENTS
    ) AS nvarchar(max));

    SET @summaryRows = REPLACE(REPLACE(@summaryRows, '<td>', '<td align="center"><font face="calibri">'), '</td>', '</font></td>');
    SET @deviationRows = REPLACE(REPLACE(ISNULL(@deviationRows, ''), '<td>', '<td align="center"><font face="calibri">'), '</td>', '</font></td>');

    SET @subject = CONCAT('SQL Patch Validation Report - ', @batch, ' - ', CONVERT(varchar(30), SYSDATETIME(), 109));
    SET @body = CONCAT(
        '<html><head><style>',
        'td{border:solid black 1px;padding:4px;font-size:10pt;}',
        'th{background-color:#4b6c9e;color:white;border:solid black 1px;padding:4px;font-family:calibri;}',
        'body{font-family:calibri;} h3{margin-bottom:4px;}',
        '</style></head><body>',
        '<h3>SQL Patch Validation Audit</h3>',
        '<table cellpadding="0" cellspacing="0"><tr><th>Patch Batch</th><th>Pre Run</th><th>Post Run</th><th>Pre Validated By</th><th>Post Validated By</th><th>Pre Time</th><th>Post Time</th></tr><tr>',
        '<td>', @batch, '</td><td>', @PreRunId, '</td><td>', @PostRunId, '</td><td>', @preBy, '</td><td>', @postBy, '</td><td>', CONVERT(varchar(19), @preStart, 120), '</td><td>', CONVERT(varchar(19), @postStart, 120), '</td></tr></table>',
        '<h3>Validation Summary</h3>',
        '<table cellpadding="0" cellspacing="0"><tr><th>Validation Type</th><th>Total Checks</th><th>Deviation Count</th></tr>',
        ISNULL(@summaryRows, ''),
        '</table>',
        '<h3>Deviation Detail</h3>',
        CASE WHEN NULLIF(@deviationRows, '') IS NULL
             THEN '<b>No deviations found between PRE and POST runs.</b>'
             ELSE CONCAT('<table cellpadding="0" cellspacing="0"><tr><th>Server</th><th>Validation Type</th><th>Result</th><th>Deviation</th><th>PRE Value</th><th>POST Value</th></tr>', @deviationRows, '</table>')
        END,
        '</body></html>'
    );

    IF @SendMail = 1
    BEGIN
        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = @MailProfile,
            @recipients = @Recipients,
            @body = @body,
            @subject = @subject,
            @body_format = 'HTML';
    END;

    SELECT
        Subject = @subject,
        HtmlBody = @body;
END;
GO
