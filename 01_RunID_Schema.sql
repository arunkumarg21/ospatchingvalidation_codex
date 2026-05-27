USE [AdminDB];
GO

IF OBJECT_ID('dbo.ValidationRun', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ValidationRun
    (
        RunId int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ValidationRun PRIMARY KEY,
        PatchBatchId varchar(100) NOT NULL,
        Stage varchar(10) NOT NULL
            CONSTRAINT CK_ValidationRun_Stage CHECK (Stage IN ('PRE','POST')),
        StartTime datetime2(0) NOT NULL
            CONSTRAINT DF_ValidationRun_StartTime DEFAULT (sysdatetime()),
        EndTime datetime2(0) NULL,
        ExecutedBy nvarchar(256) NOT NULL,
        ExecutionHost nvarchar(128) NOT NULL,
        TotalServers int NOT NULL
            CONSTRAINT DF_ValidationRun_TotalServers DEFAULT (0),
        OverallStatus varchar(30) NOT NULL
            CONSTRAINT DF_ValidationRun_OverallStatus DEFAULT ('RUNNING'),
        Message nvarchar(max) NULL
    );
END;
GO

IF OBJECT_ID('dbo.ValidationResult', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ValidationResult
    (
        ResultId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ValidationResult PRIMARY KEY,
        RunId int NOT NULL
            CONSTRAINT FK_ValidationResult_ValidationRun
            REFERENCES dbo.ValidationRun(RunId),
        ServerName sysname NOT NULL,
        ValidationType varchar(60) NOT NULL,
        ResultName nvarchar(256) NOT NULL,
        ResultKey nvarchar(512) NOT NULL,
        ExpectedValue nvarchar(max) NULL,
        ActualValue nvarchar(max) NULL,
        ValidationStatus varchar(20) NOT NULL
            CONSTRAINT CK_ValidationResult_Status CHECK (ValidationStatus IN ('PASS','FAIL','WARN','INFO','ERROR')),
        DetailsJson nvarchar(max) NULL,
        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_ValidationResult_CreatedAt DEFAULT (sysdatetime())
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ValidationRun_BatchStage' AND object_id = OBJECT_ID('dbo.ValidationRun'))
BEGIN
    CREATE INDEX IX_ValidationRun_BatchStage
    ON dbo.ValidationRun(PatchBatchId, Stage, RunId DESC)
    INCLUDE (StartTime, EndTime, ExecutedBy, ExecutionHost, OverallStatus, TotalServers);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ValidationResult_Run_Compare' AND object_id = OBJECT_ID('dbo.ValidationResult'))
BEGIN
    CREATE INDEX IX_ValidationResult_Run_Compare
    ON dbo.ValidationResult(RunId, ServerName, ValidationType, ResultKey)
    INCLUDE (ResultName, ValidationStatus, CreatedAt);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ValidationResult_ServerType' AND object_id = OBJECT_ID('dbo.ValidationResult'))
BEGIN
    CREATE INDEX IX_ValidationResult_ServerType
    ON dbo.ValidationResult(ServerName, ValidationType, RunId);
END;
GO
