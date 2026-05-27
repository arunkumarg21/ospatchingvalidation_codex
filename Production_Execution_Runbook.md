# Production SQL Patch Validation Runbook

## Purpose

This runbook avoids patch-window trial and error. Use one wrapper command for PRE and one wrapper command for POST.

The wrapper performs:

1. SQL module unblock/import check.
2. SQL connectivity test using `TrustServerCertificate`.
3. Creation of `PatchingServers.Validated.txt`.
4. RunID validation using either FAST or FULL mode.
5. Timeout-protected collection.
6. Result storage in `AdminDB.dbo.ValidationRun` and `AdminDB.dbo.ValidationResult`.

## Files To Copy To Production

Copy the complete folder:

```text
C:\temp\Phase1_RunID_Framework
```

Required files:

```text
settings.production.fast.json
settings.production.full.json
Scripts\Invoke-PatchValidationProduction.ps1
Scripts\Invoke-ProductionPreflight.ps1
Scripts\Invoke-Validation.ps1
Modules\Common.psm1
Modules\Logging.psm1
Sql\01_RunID_Schema.sql
Sql\02_RunID_Procedures.sql
Sql\04_Report_Procedure.sql
```

## Server List

Create:

```text
C:\temp\PatchingServers.txt
```

Add SQL instance names only:

```text
SQL01
SQL02
SQL03\INST1
```

The wrapper creates:

```text
C:\temp\PatchingServers.Validated.txt
```

Only instances that pass SQL connectivity are validated.

## PATCH Mode

Use this during the actual patch window. This is the recommended production mode.

PATCH mode focuses on current patch evidence and recent errors, not broad history.

Checks:

```text
ServerStatus
DatabaseStatus
FailedAgentJobs             last 60 minutes
AvailabilityGroupStatus
LogShippingStatus
ReplicationJobs
SqlErrorLogSeverity         severity 17+ in last 1 hour
WindowsEventLog             Critical/Error in last 1 hour
SQLBuildVersion             PRE to POST build comparison
WindowsPatchHistory         latest installed KB only
```

Run PRE:

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\Phase1_RunID_Framework\Scripts\Invoke-PatchValidationProduction.ps1" -Stage PRE -PatchBatchId "MAY2026-PROD-WAVE1" -Mode PATCH -FrameworkRoot "C:\temp\Phase1_RunID_Framework" -RawServerListFile "C:\temp\PatchingServers.txt" -ValidatedServerListFile "C:\temp\PatchingServers.Validated.txt"
```

Run POST:

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\Phase1_RunID_Framework\Scripts\Invoke-PatchValidationProduction.ps1" -Stage POST -PatchBatchId "MAY2026-PROD-WAVE1" -Mode PATCH -FrameworkRoot "C:\temp\Phase1_RunID_Framework" -RawServerListFile "C:\temp\PatchingServers.txt" -ValidatedServerListFile "C:\temp\PatchingServers.Validated.txt"
```

PATCH mode timeout profile:

```text
CommandTimeoutSeconds       = 20
SqlConnectionTimeoutSeconds = 5
ValidationTimeoutSeconds    = 30
RetryCount                  = 0
```

## FAST Mode

Legacy lightweight mode. Use only if you intentionally want fewer checks.

Checks:

```text
ServerStatus
DatabaseStatus
FailedAgentJobs
AvailabilityGroupStatus
LogShippingStatus
ReplicationJobs
SQLBuildVersion
WindowsPatchHistory
```

Run PRE:

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\Phase1_RunID_Framework\Scripts\Invoke-PatchValidationProduction.ps1" -Stage PRE -PatchBatchId "MAY2026-PROD-WAVE1" -Mode FAST -FrameworkRoot "C:\temp\Phase1_RunID_Framework" -RawServerListFile "C:\temp\PatchingServers.txt" -ValidatedServerListFile "C:\temp\PatchingServers.Validated.txt"
```

Run POST:

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\Phase1_RunID_Framework\Scripts\Invoke-PatchValidationProduction.ps1" -Stage POST -PatchBatchId "MAY2026-PROD-WAVE1" -Mode FAST -FrameworkRoot "C:\temp\Phase1_RunID_Framework" -RawServerListFile "C:\temp\PatchingServers.txt" -ValidatedServerListFile "C:\temp\PatchingServers.Validated.txt"
```

## FULL Mode

Use after patch window only if deeper evidence is required.

Checks:

```text
SQLServices
WindowsServices
MirroringStatus
WindowsClusterStatus
SqlErrorLogSeverity
WindowsEventLog
```

plus all FAST checks.

FULL mode is tuned for production speed with strict timeouts:

```text
CommandTimeoutSeconds       = 30
SqlConnectionTimeoutSeconds = 5
ValidationTimeoutSeconds    = 45
WindowsEventLogLookback     = 30 minutes
```

This means FULL mode is robust: a slow Windows, cluster, event log, or SQL call is terminated and recorded as `ERROR` instead of blocking the whole validation.

Run:

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\temp\Phase1_RunID_Framework\Scripts\Invoke-PatchValidationProduction.ps1" -Stage POST -PatchBatchId "MAY2026-PROD-WAVE1-FULL" -Mode FULL -FrameworkRoot "C:\temp\Phase1_RunID_Framework" -RawServerListFile "C:\temp\PatchingServers.txt" -ValidatedServerListFile "C:\temp\PatchingServers.Validated.txt"
```

## Report

Preview HTML:

```sql
EXEC AdminDB.dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId = 'MAY2026-PROD-WAVE1',
    @SendMail = 0;
```

Send email:

```sql
EXEC AdminDB.dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId = 'MAY2026-PROD-WAVE1',
    @SendMail = 1,
    @MailProfile = 'Production Database Mail',
    @Recipients = 'dba-team@company.com';
```

## Status Meaning

```text
PASS  = healthy
WARN  = health deviation found
ERROR = collector/connectivity/timeout failure
INFO  = optional feature not configured or informational capture
```

Optional features are not treated as failures when not configured.
