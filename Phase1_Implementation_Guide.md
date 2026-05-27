# SQL Patch Validation Framework - Phase 1 Refactor

## Objective

Phase 1 keeps the existing operational model: SQL Agent starts PowerShell, PowerShell collects health data, SQL stores results, and SQL sends an HTML report.

The improvement is architectural:

- Replace duplicate `_BP` and `_AP` scripts with one parameterized runner using `-Stage PRE` or `-Stage POST`.
- Replace separate BP/AP tables with `ValidationRun` and `ValidationResult`.
- Capture audit metadata: DBA username, host, start time, end time, patch batch, total servers, and status.
- Centralize logging and shared PowerShell helper logic.
- Move environment values into `settings.json`.
- Preserve the current validation areas: server ping, SQL services, database status, mirroring, log shipping, AG, and SQL error log.

## New Folder Layout

```text
Phase1_RunID_Framework
|-- settings.json
|-- Modules
|   |-- Common.psm1
|   |-- Logging.psm1
|-- Scripts
|   |-- Invoke-Validation.ps1
|-- Sql
|   |-- 01_RunID_Schema.sql
|   |-- 02_RunID_Procedures.sql
|   |-- 03_SQL_Agent_Job_Template.sql
|   |-- 04_Report_Procedure.sql
|-- Docs
|   |-- Phase1_Implementation_Guide.md
```

## Recommended Deployment Steps

### 1. Backup the Current Framework

Before deployment, back up the existing folder and AdminDB objects.

```powershell
Copy-Item E:\OS_Patching_Validation E:\OS_Patching_Validation_Backup_$(Get-Date -Format yyyyMMddHHmmss) -Recurse
```

Also script out the current AP/BP tables, SQL Agent jobs, and `usp_after_patching_summary_mail`.

### 2. Deploy the New Framework Folder

Copy `Phase1_RunID_Framework` to the operational path, for example:

```text
E:\OS_Patching_Validation\Phase1_RunID_Framework
```

Do not delete the current scripts yet. Run the RunID framework in parallel for at least one patch cycle.

### 3. Update `settings.json`

Set these values for the target environment:

- `RepositoryServer`
- `RepositoryDatabase`
- `ServerListFile`
- `LogRoot`
- `DatabaseMailProfile`
- `MailRecipients`
- `RetryCount`
- `RetryDelaySeconds`
- `CommandTimeoutSeconds`
- `RetentionDays`

Use separate copies of `settings.json` for Production, UAT, and DR if the values differ.

### 4. Create the RunID SQL Objects

Run these scripts in order against `AdminDB`:

```sql
:r .\Sql\01_RunID_Schema.sql
:r .\Sql\02_RunID_Procedures.sql
```

The mail report procedure is also provided separately as `Sql\04_Report_Procedure.sql` for easy review or redeployment.

Important: `01_RunID_Schema.sql` creates the new `ValidationRun` and `ValidationResult` tables only if they do not already exist. It does not drop your existing AP/BP temp tables.

### 5. Test a PRE Run Manually

From a PowerShell session running as the DBA or SQL Agent proxy account:

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\OS_Patching_Validation\Phase1_RunID_Framework\Scripts\Invoke-Validation.ps1" -Stage PRE -PatchBatchId "MAY2026-PROD-WAVE1" -ConfigPath "E:\OS_Patching_Validation\Phase1_RunID_Framework\settings.json"
```

Validate:

```sql
SELECT * FROM dbo.ValidationRun ORDER BY RunId DESC;
SELECT TOP (100) * FROM dbo.ValidationResult ORDER BY ResultId DESC;
```

### 6. Test a POST Run Manually

```powershell
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\OS_Patching_Validation\Phase1_RunID_Framework\Scripts\Invoke-Validation.ps1" -Stage POST -PatchBatchId "MAY2026-PROD-WAVE1" -ConfigPath "E:\OS_Patching_Validation\Phase1_RunID_Framework\settings.json"
```

Generate the report without sending email first:

```sql
EXEC dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId = 'MAY2026-PROD-WAVE1',
    @SendMail = 0;
```

When the HTML output is verified, test email:

```sql
EXEC dbo.usp_PatchValidation_SummaryMail_RunID
    @PatchBatchId = 'MAY2026-PROD-WAVE1',
    @SendMail = 1,
    @MailProfile = 'Production Database Mail',
    @Recipients = 'dba-team@company.com';
```

### 7. Create SQL Agent Jobs

Edit `Sql\03_SQL_Agent_Job_Template.sql`:

- Set `@ScriptRoot`.
- Set `@PatchBatchId`.
- Set Database Mail profile and recipients.

Then run the script in `msdb`.

This creates:

- `SQL_health_checks_PRE_RunID`
- `SQL_health_checks_POST_RunID`

### 8. Parallel Run Recommendation

For the first patching cycle:

1. Run the current BP/AP framework as usual.
2. Run the new PRE/POST RunID jobs.
3. Compare the old HTML report against the new RunID report.
4. Verify row counts and deviations.
5. Only after confidence is established, retire the duplicate AP/BP scripts.

## Mapping From Current Scripts

| Current Scripts | New Execution |
| --- | --- |
| `serverstatus_BP.ps1`, `serverstatus_AP.ps1` | `Invoke-Validation.ps1 -Stage PRE/POST`, validation type `ServerStatus` |
| `SQLServicesStatus_BP.ps1`, `SQLServicesStatus_AP.ps1` | `SQLServices` |
| `DB_status_BP.ps1`, `DB_status_AP.ps1` | `DatabaseStatus` |
| `MirroringStatus_BP.ps1`, `MirroringStatus_AP.ps1` | `MirroringStatus` |
| `LogShippingStatus_BP.ps1`, `LogShippingStatus_AP.ps1` | `LogShippingStatus` |
| `AAGStatus_BP.ps1`, `AAGStatus_AP.ps1` | `AvailabilityGroupStatus` |
| Existing report procedure | `usp_PatchValidation_SummaryMail_RunID` |

## Validation Coverage Matrix

| Required Check | Covered | Validation Type |
| --- | --- | --- |
| SQL services status | Yes | `SQLServices` |
| Database states: online, offline, suspect, restoring, recovery pending | Yes | `DatabaseStatus` |
| Failed SQL Agent jobs in the last 30 minutes | Yes | `FailedAgentJobs` |
| Log Shipping status | Yes | `LogShippingStatus` |
| Replication jobs | Yes | `ReplicationJobs` |
| Always On AG sync and roles | Yes | `AvailabilityGroupStatus` |
| Windows Cluster nodes, groups, and owners | Yes | `WindowsClusterStatus` |
| Windows services state | Yes | `WindowsServices` |
| SQL services state | Yes | `SQLServices` |
| SQL Error Log severity 17 and above | Yes | `SqlErrorLogSeverity` |
| Windows Event Log Critical and Error events | Yes | `WindowsEventLog` |
| SQL build version for PRE to POST comparison | Yes | `SQLBuildVersion` |
| Windows patch history, last 5 KBs | Yes | `WindowsPatchHistory` |

The default lookback and count values are controlled in `settings.json`:

- `AgentJobFailureLookbackMinutes`: default `30`
- `WindowsEventLogLookbackMinutes`: default `60`
- `WindowsPatchHistoryCount`: default `5`
- `WindowsServices`: list of Windows service names to validate
- `SqlConnectionTimeoutSeconds`: SQL connection timeout, recommended `5`
- `ValidationTimeoutSeconds`: hard timeout for each server/check child process

For production, keep child process isolation enabled. This is the default behavior. Each server/check is executed by a separate PowerShell process. If a remote WMI, event log, cluster, SQL, or patch-history call hangs, the child process is terminated after `ValidationTimeoutSeconds`, the result is stored as `ERROR`, and the framework continues to the next validation.

Only use `-DisableIsolation` for troubleshooting a single check interactively.

Optional features are feature-aware. If Mirroring, Log Shipping, Replication, Always On AG, or Windows Cluster is not configured on a server, the framework records an `INFO` result such as `NotConfigured` or `HadrNotEnabled` instead of failing the validation.

## DBA Audit Evidence

Each run captures:

- `RunId`
- `PatchBatchId`
- `Stage`
- `StartTime`
- `EndTime`
- `ExecutedBy`
- `ExecutionHost`
- `TotalServers`
- `OverallStatus`
- `Message`

This query is suitable for patch evidence:

```sql
SELECT
    RunId,
    PatchBatchId,
    Stage,
    StartTime,
    EndTime,
    ExecutedBy,
    ExecutionHost,
    TotalServers,
    OverallStatus
FROM dbo.ValidationRun
ORDER BY RunId DESC;
```

## Recommended Phase 1 Enhancements

- Add a retention job that archives or deletes `ValidationResult` rows older than `settings.json.RetentionDays`.
- Add a `ServerInventory` table later if server ownership, application name, environment, and criticality must be shown in reports.
- Add SQL Agent proxy credentials if the SQL Agent service account should not directly perform remote WMI and SQL checks.
- Add a `PatchBatch` master table if CAB/change ticket IDs, wave names, and application approvals need formal tracking.
- Keep the old AP/BP objects read-only for at least one audit period before cleanup.
