[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PRE','POST')]
    [string]$Stage,

    [Parameter(Mandatory)]
    [string]$PatchBatchId,

    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\settings.json'),

    [int]$RunId,

    [string[]]$ValidationTypes,

    [string]$ServerName,

    [switch]$Worker,

    [switch]$DisableIsolation,

    [int]$ValidationTimeoutSeconds = 0
)

$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\Modules'
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'Logging.psm1') -Force
Import-Module (Join-Path -Path $moduleRoot -ChildPath 'Common.psm1') -Force

function ConvertTo-CommandArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-ValidationChildProcess {
    param(
        [Parameter(Mandatory)][int]$CurrentRunId,
        [Parameter(Mandatory)][string]$CurrentServerName,
        [Parameter(Mandatory)][string]$CurrentValidationType,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $powerShellExe = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
    if (-not (Test-Path -Path $powerShellExe -PathType Leaf)) {
        $powerShellExe = 'PowerShell.exe'
    }

    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        '-File', (ConvertTo-CommandArgument $PSCommandPath)
        '-Stage', $Stage
        '-PatchBatchId', (ConvertTo-CommandArgument $PatchBatchId)
        '-ConfigPath', (ConvertTo-CommandArgument $ConfigPath)
        '-RunId', $CurrentRunId
        '-ServerName', (ConvertTo-CommandArgument $CurrentServerName)
        '-ValidationTypes', (ConvertTo-CommandArgument $CurrentValidationType)
        '-Worker'
        '-ValidationTimeoutSeconds', $TimeoutSeconds
    ) -join ' '

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    Write-ValidationLog -Message ("Launching isolated check. TimeoutSeconds={0}" -f $TimeoutSeconds) -ServerName $CurrentServerName -ValidationType $CurrentValidationType
    [void]$process.Start()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill()
        }
        catch {
            Write-ValidationLog -Level WARN -Message 'Failed to kill timed-out child process.' -ServerName $CurrentServerName -ValidationType $CurrentValidationType -Exception $_.Exception
        }

        Write-ValidationLog -Level ERROR -Message 'Validation timed out and was terminated.' -ServerName $CurrentServerName -ValidationType $CurrentValidationType
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $CurrentServerName `
            -ValidationType $CurrentValidationType -ResultName 'ValidationTimeout' -ResultKey "$CurrentValidationType|ValidationTimeout" `
            -ExpectedValue "Complete within $TimeoutSeconds seconds" -ActualValue 'Timed out and terminated' -ValidationStatus 'ERROR' `
            -Details @{ TimeoutSeconds = $TimeoutSeconds; Isolation = 'ChildProcess' }
        return
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    if ($stdout) {
        Write-ValidationLog -Level DEBUG -Message ($stdout.Trim()) -ServerName $CurrentServerName -ValidationType $CurrentValidationType
    }

    if ($process.ExitCode -ne 0) {
        $errorText = if ($stderr) { $stderr.Trim() } else { "Child process failed with exit code $($process.ExitCode)" }
        Write-ValidationLog -Level ERROR -Message $errorText -ServerName $CurrentServerName -ValidationType $CurrentValidationType
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $CurrentServerName `
            -ValidationType $CurrentValidationType -ResultName 'ValidationProcessFailure' -ResultKey "$CurrentValidationType|ValidationProcessFailure" `
            -ExpectedValue 'Child process exit code 0' -ActualValue $errorText -ValidationStatus 'ERROR' `
            -Details @{ ExitCode = $process.ExitCode; StandardError = $stderr }
    }
}

function Invoke-ServerStatusValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $online = Test-Connection -ComputerName $ServerName -BufferSize 32 -Count 1 -Quiet
    $actual = if ($online) { 'Online' } else { 'Offline' }
    $status = if ($online) { 'PASS' } else { 'FAIL' }

    Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
        -ValidationType 'ServerStatus' -ResultName 'PingStatus' -ResultKey 'ServerStatus|PingStatus' `
        -ExpectedValue 'Online' -ActualValue $actual -ValidationStatus $status `
        -Details @{ ComputerName = $ServerName; Check = 'ICMP ping' }
}

function Invoke-SQLServicesValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $services = Get-WmiObject Win32_Service -ComputerName $ServerName |
        Where-Object { $_.Name -like 'SQLAGENT*' -or $_.Name -like '*SQL*' } |
        Select-Object Name, StartMode, State

    foreach ($service in $services) {
        $expected = if ($service.StartMode -eq 'Disabled') { 'Stopped' } else { 'Running' }
        $validationStatus = if ($service.StartMode -eq 'Disabled' -or $service.State -eq 'Running') { 'PASS' } else { 'WARN' }
        $key = 'SQLServices|{0}' -f $service.Name

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'SQLServices' -ResultName $service.Name -ResultKey $key `
            -ExpectedValue $expected -ActualValue $service.State -ValidationStatus $validationStatus `
            -Details @{ Name = $service.Name; StartMode = $service.StartMode; State = $service.State }
    }
}

function Invoke-DatabaseStatusValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $query = "SELECT @@SERVERNAME AS ServerName, name AS DatabaseName, state_desc AS Status FROM sys.databases;"
    $rows = Invoke-TargetQuery -ServerInstance $ServerName -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate

    foreach ($row in $rows) {
        $status = if ($row.Status -eq 'ONLINE') { 'PASS' } else { 'WARN' }
        $key = 'DatabaseStatus|{0}' -f $row.DatabaseName

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'DatabaseStatus' -ResultName $row.DatabaseName -ResultKey $key `
            -ExpectedValue 'ONLINE' -ActualValue $row.Status -ValidationStatus $status `
            -Details @{ DatabaseName = $row.DatabaseName; State = $row.Status }
    }
}

function Invoke-FailedAgentJobsValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $lookback = if ($Config.AgentJobFailureLookbackMinutes) { [int]$Config.AgentJobFailureLookbackMinutes } else { 30 }
    $query = @"
DECLARE @Since datetime = DATEADD(MINUTE, -$lookback, GETDATE());

WITH JobHistory AS
(
    SELECT
        j.name AS JobName,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS RunDateTime,
        h.run_status,
        h.message
    FROM msdb.dbo.sysjobhistory h
    INNER JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
    WHERE h.step_id = 0
      AND h.run_status = 0
      AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= @Since
)
SELECT @@SERVERNAME AS ServerName, JobName, RunDateTime, message
FROM JobHistory
ORDER BY RunDateTime DESC;
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -DatabaseName 'msdb' -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $rows) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'FailedAgentJobs' -ResultName 'Last30Minutes' -ResultKey 'FailedAgentJobs|Last30Minutes' `
            -ExpectedValue '0 failed jobs' -ActualValue '0 failed jobs' -ValidationStatus 'PASS' `
            -Details @{ LookbackMinutes = $lookback }
        return
    }

    foreach ($row in $rows) {
        $key = 'FailedAgentJobs|{0}|{1:yyyyMMddHHmmss}' -f $row.JobName, $row.RunDateTime
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'FailedAgentJobs' -ResultName $row.JobName -ResultKey $key `
            -ExpectedValue 'No failed jobs' -ActualValue $row.message -ValidationStatus 'FAIL' `
            -Details $row
    }
}

function Invoke-MirroringStatusValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $query = @"
SELECT
    @@SERVERNAME AS ServerName,
    d.name AS DatabaseName,
    ISNULL(dm.mirroring_state_desc, 'NOT_MIRRORED') AS mirroring_state_desc,
    ISNULL(dm.mirroring_role_desc, 'NOT_MIRRORED') AS mirroring_role_desc,
    ISNULL(dm.mirroring_partner_instance, '') AS mirroring_partner_instance
FROM sys.databases d
LEFT JOIN sys.database_mirroring dm ON d.database_id = dm.database_id
WHERE dm.mirroring_guid IS NOT NULL;
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $rows) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'MirroringStatus' -ResultName 'MirroringNotConfigured' -ResultKey 'MirroringStatus|NotConfigured' `
            -ExpectedValue 'Optional feature' -ActualValue 'No mirrored databases found' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName; FeatureConfigured = $false }
        return
    }

    foreach ($row in $rows) {
        $status = if ($row.mirroring_state_desc -eq 'SYNCHRONIZED') { 'PASS' } else { 'WARN' }
        $key = 'MirroringStatus|{0}' -f $row.DatabaseName

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'MirroringStatus' -ResultName $row.DatabaseName -ResultKey $key `
            -ExpectedValue 'SYNCHRONIZED' -ActualValue $row.mirroring_state_desc -ValidationStatus $status `
            -Details @{
                DatabaseName = $row.DatabaseName
                MirroringState = $row.mirroring_state_desc
                MirroringRole = $row.mirroring_role_desc
                PartnerInstance = $row.mirroring_partner_instance
            }
    }
}

function Invoke-LogShippingStatusValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $query = @"
IF OBJECT_ID('msdb.dbo.log_shipping_monitor_secondary') IS NOT NULL
BEGIN
    SELECT
        @@SERVERNAME AS ServerName,
        primary_server,
        primary_database,
        restore_delay,
        time_since_last_restore,
        last_copied_date,
        last_restored_date,
        last_copied_file,
        last_restored_file,
        disconnect_users,
        backup_source_directory,
        backup_destination_directory,
        monitor_server
    FROM msdb.dbo.log_shipping_monitor_secondary;
END
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -DatabaseName 'msdb' -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $rows) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'LogShippingStatus' -ResultName 'LogShippingNotConfigured' -ResultKey 'LogShippingStatus|NotConfigured' `
            -ExpectedValue 'Optional feature' -ActualValue 'No log shipping configuration found' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName; FeatureConfigured = $false }
        return
    }

    foreach ($row in $rows) {
        $key = 'LogShippingStatus|{0}|{1}' -f $row.primary_server, $row.primary_database

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'LogShippingStatus' -ResultName $row.primary_database -ResultKey $key `
            -ExpectedValue 'No POST deviation from PRE' -ActualValue ('LastRestored={0}' -f $row.last_restored_date) -ValidationStatus 'INFO' `
            -Details $row
    }
}

function Invoke-ReplicationJobsValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $query = @"
SELECT
    @@SERVERNAME AS ServerName,
    j.name AS JobName,
    ISNULL(c.name, '') AS CategoryName,
    CASE
        WHEN ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL THEN 'Running'
        WHEN h.run_status = 0 THEN 'Failed'
        WHEN h.run_status = 1 THEN 'Succeeded'
        WHEN h.run_status = 3 THEN 'Cancelled'
        ELSE 'Unknown'
    END AS JobState,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS LastRunTime,
    h.message AS LastRunMessage
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysjobactivity ja
    ON ja.job_id = j.job_id
   AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
OUTER APPLY
(
    SELECT TOP (1) h.*
    FROM msdb.dbo.sysjobhistory h
    WHERE h.job_id = j.job_id
      AND h.step_id = 0
    ORDER BY h.instance_id DESC
) h
WHERE c.name LIKE 'REPL%'
   OR j.name LIKE 'REPL-%'
   OR j.name LIKE '%Log Reader Agent%'
   OR j.name LIKE '%Distribution Agent%'
   OR j.name LIKE '%Snapshot Agent%'
   OR j.name LIKE '%Merge Agent%';
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -DatabaseName 'msdb' -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $rows) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'ReplicationJobs' -ResultName 'ReplicationJobs' -ResultKey 'ReplicationJobs|NoneFound' `
            -ExpectedValue 'No failed replication jobs' -ActualValue 'No replication jobs found' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName }
        return
    }

    foreach ($row in $rows) {
        $status = if ($row.JobState -eq 'Failed') { 'FAIL' } else { 'PASS' }
        $key = 'ReplicationJobs|{0}' -f $row.JobName
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'ReplicationJobs' -ResultName $row.JobName -ResultKey $key `
            -ExpectedValue 'Not Failed' -ActualValue $row.JobState -ValidationStatus $status `
            -Details $row
    }
}

function Invoke-AvailabilityGroupStatusValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $hadrState = Invoke-TargetQuery -ServerInstance $ServerName -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled;" -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $hadrState -or [int]$hadrState.IsHadrEnabled -ne 1) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'AvailabilityGroupStatus' -ResultName 'HadrNotEnabled' -ResultKey 'AvailabilityGroupStatus|HadrNotEnabled' `
            -ExpectedValue 'Optional feature' -ActualValue 'Always On HADR is not enabled' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName; IsHadrEnabled = $false }
        return
    }

    $roleQuery = @"
IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    SELECT
        @@SERVERNAME AS ServerName,
        ISNULL(lip.state_desc, 'null') AS state,
        ISNULL(lip.ip_address, 'null') AS ip_address,
        CONVERT(varchar(60), AGC.name) AS AG_Name,
        ISNULL(l.dns_name, @@SERVERNAME) + ':' + CAST(ISNULL(l.port, 0) AS varchar(8)) AS Listener,
        CASE
            WHEN ARS.role = 1 THEN RCS.replica_server_name
            ELSE (SELECT TOP 1 replica_server_name FROM sys.dm_hadr_availability_replica_cluster_states RCS2
                  INNER JOIN sys.dm_hadr_availability_replica_states ARS2 ON ARS2.replica_id = RCS2.replica_id
                  WHERE ARS2.role = 1)
        END AS active_node,
        CASE
            WHEN ARS.role = 2 THEN RCS.replica_server_name
            ELSE (SELECT TOP 1 replica_server_name FROM sys.dm_hadr_availability_replica_cluster_states RCS2
                  INNER JOIN sys.dm_hadr_availability_replica_states ARS2 ON ARS2.replica_id = RCS2.replica_id
                  WHERE ARS2.role = 2)
        END AS passive_node,
        ARS.role_desc
    FROM sys.availability_groups_cluster AGC
    INNER JOIN sys.dm_hadr_availability_replica_cluster_states RCS ON RCS.group_id = AGC.group_id
    INNER JOIN sys.dm_hadr_availability_replica_states ARS ON ARS.replica_id = RCS.replica_id
    LEFT JOIN sys.availability_group_listeners l ON l.group_id = ARS.group_id
    LEFT JOIN sys.availability_group_listener_ip_addresses lip ON lip.listener_id = l.listener_id
    WHERE RCS.replica_server_name = CONVERT(sysname, SERVERPROPERTY('ServerName'));
END
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -Query $roleQuery -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $rows) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'AvailabilityGroupStatus' -ResultName 'AGNotConfigured' -ResultKey 'AvailabilityGroupStatus|AGNotConfigured' `
            -ExpectedValue 'Optional feature' -ActualValue 'HADR enabled but no local AG replica found' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName; IsHadrEnabled = $true; FeatureConfigured = $false }
        return
    }

    foreach ($row in $rows) {
        $key = 'AvailabilityGroupStatus|Role|{0}|{1}' -f $row.AG_Name, $row.Listener

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'AvailabilityGroupStatus' -ResultName ('Role|{0}' -f $row.AG_Name) -ResultKey $key `
            -ExpectedValue 'No POST deviation from PRE' -ActualValue $row.role_desc -ValidationStatus 'INFO' `
            -Details $row
    }

    $syncQuery = @"
IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    SELECT
        @@SERVERNAME AS ServerName,
        ag.name AS AG_Name,
        DB_NAME(drs.database_id) AS DatabaseName,
        ars.role_desc,
        drs.synchronization_state_desc,
        drs.synchronization_health_desc,
        drs.database_state_desc,
        drs.is_failover_ready
    FROM sys.dm_hadr_database_replica_states drs
    INNER JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
    INNER JOIN sys.dm_hadr_availability_replica_states ars
        ON ars.replica_id = drs.replica_id
       AND ars.group_id = drs.group_id
    WHERE drs.is_local = 1;
END
"@

    $syncRows = Invoke-TargetQuery -ServerInstance $ServerName -Query $syncQuery -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    foreach ($row in $syncRows) {
        $actual = '{0}; Health={1}; Role={2}' -f $row.synchronization_state_desc, $row.synchronization_health_desc, $row.role_desc
        $status = if ($row.synchronization_health_desc -eq 'HEALTHY') { 'PASS' } else { 'WARN' }
        $key = 'AvailabilityGroupStatus|Sync|{0}|{1}' -f $row.AG_Name, $row.DatabaseName

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'AvailabilityGroupStatus' -ResultName ('Sync|{0}|{1}' -f $row.AG_Name, $row.DatabaseName) -ResultKey $key `
            -ExpectedValue 'HEALTHY' -ActualValue $actual -ValidationStatus $status `
            -Details $row
    }
}

function Invoke-WindowsClusterStatusValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $clusterService = Get-WmiObject Win32_Service -ComputerName $ServerName -Filter "Name='ClusSvc'" -ErrorAction Stop
    if (-not $clusterService -or $clusterService.State -ne 'Running') {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsClusterStatus' -ResultName 'ClusterNotConfigured' -ResultKey 'WindowsClusterStatus|NotConfigured' `
            -ExpectedValue 'Optional feature' -ActualValue 'Cluster service is not present or not running' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName; FeatureConfigured = $false; ClusterServiceState = $(if ($clusterService) { $clusterService.State } else { 'NotFound' }) }
        return
    }

    try {
        Import-Module FailoverClusters -ErrorAction Stop
    }
    catch {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsClusterStatus' -ResultName 'FailoverClustersModuleMissing' -ResultKey 'WindowsClusterStatus|ModuleMissing' `
            -ExpectedValue 'FailoverClusters module available when cluster checks are required' -ActualValue 'FailoverClusters module not available on execution host' -ValidationStatus 'INFO' `
            -Details @{ ServerName = $ServerName; FeatureConfigured = $true; Error = $_.Exception.Message }
        return
    }

    $nodes = Get-ClusterNode -Cluster $ServerName -ErrorAction Stop
    foreach ($node in $nodes) {
        $status = if ($node.State -eq 'Up') { 'PASS' } else { 'FAIL' }
        $key = 'WindowsClusterStatus|Node|{0}' -f $node.Name
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsClusterStatus' -ResultName $node.Name -ResultKey $key `
            -ExpectedValue 'Up' -ActualValue $node.State -ValidationStatus $status `
            -Details @{ ObjectType = 'Node'; Name = $node.Name; State = $node.State }
    }

    $groups = Get-ClusterGroup -Cluster $ServerName -ErrorAction Stop
    foreach ($group in $groups) {
        $status = if ($group.State -eq 'Online') { 'PASS' } else { 'WARN' }
        $key = 'WindowsClusterStatus|Group|{0}' -f $group.Name
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsClusterStatus' -ResultName $group.Name -ResultKey $key `
            -ExpectedValue 'Online' -ActualValue ('{0}; Owner={1}' -f $group.State, $group.OwnerNode.Name) -ValidationStatus $status `
            -Details @{ ObjectType = 'Group'; Name = $group.Name; State = $group.State; OwnerNode = $group.OwnerNode.Name }
    }
}

function Invoke-WindowsServicesValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $serviceNames = @($Config.WindowsServices)
    foreach ($serviceName in $serviceNames) {
        $service = Get-WmiObject Win32_Service -ComputerName $ServerName -Filter "Name='$serviceName'" -ErrorAction Stop
        if (-not $service) {
            Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
                -ValidationType 'WindowsServices' -ResultName $serviceName -ResultKey "WindowsServices|$serviceName" `
                -ExpectedValue 'Service present' -ActualValue 'Not found' -ValidationStatus 'INFO' `
                -Details @{ Name = $serviceName }
            continue
        }

        $expected = if ($service.StartMode -eq 'Disabled') { 'Stopped' } else { 'Running' }
        $status = if ($service.StartMode -eq 'Disabled' -or $service.State -eq 'Running') { 'PASS' } else { 'WARN' }
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsServices' -ResultName $service.Name -ResultKey "WindowsServices|$($service.Name)" `
            -ExpectedValue $expected -ActualValue $service.State -ValidationStatus $status `
            -Details @{ Name = $service.Name; DisplayName = $service.DisplayName; StartMode = $service.StartMode; State = $service.State }
    }
}

function Invoke-SqlErrorLogSeverityValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $lookbackHours = if ($Config.ErrorLogLookbackHours) { [int]$Config.ErrorLogLookbackHours } else { 1 }
    $query = @"
DECLARE @errorlog table
(
    LogDate datetime,
    ProcessInfo nvarchar(100),
    [Text] nvarchar(max)
);

DECLARE @Since nvarchar(25) = CONVERT(nvarchar(25), DATEADD(HOUR, -$lookbackHours, GETDATE()), 120);

INSERT @errorlog
EXEC master.dbo.xp_readerrorlog 0, 1, NULL, NULL, @Since, NULL;

SELECT TOP (10)
    @@SERVERNAME AS ServerName,
    LogDate,
    ProcessInfo,
    [Text]
FROM @errorlog
WHERE
(
       [Text] LIKE '%Severity: 17%'
    OR [Text] LIKE '%Severity: 18%'
    OR [Text] LIKE '%Severity: 19%'
    OR [Text] LIKE '%Severity: 20%'
    OR [Text] LIKE '%Severity: 21%'
    OR [Text] LIKE '%Severity: 22%'
    OR [Text] LIKE '%Severity: 23%'
    OR [Text] LIKE '%Severity: 24%'
    OR [Text] LIKE '%Severity: 25%'
)
ORDER BY LogDate DESC;
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    if (-not $rows) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'SqlErrorLogSeverity' -ResultName 'Severity17Plus' -ResultKey 'SqlErrorLogSeverity|Severity17Plus' `
            -ExpectedValue 'No severity 17+ entries' -ActualValue 'No severity 17+ entries found' -ValidationStatus 'PASS' `
            -Details @{ ServerName = $ServerName; LookbackHours = $lookbackHours }
        return
    }

    foreach ($row in $rows) {
        $key = 'SqlErrorLogSeverity|{0:yyyyMMddHHmmss}|{1}' -f $row.LogDate, $row.ProcessInfo

        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'SqlErrorLogSeverity' -ResultName $row.ProcessInfo -ResultKey $key `
            -ExpectedValue 'No severity 17+ entries' -ActualValue $row.Text -ValidationStatus 'WARN' `
            -Details $row
    }
}

function Invoke-WindowsEventLogValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $lookback = if ($Config.WindowsEventLogLookbackMinutes) { [int]$Config.WindowsEventLogLookbackMinutes } else { 60 }
    $startTime = (Get-Date).AddMinutes(-1 * $lookback)
    $events = Get-WinEvent -ComputerName $ServerName -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = $startTime } -ErrorAction Stop |
        Select-Object -First 50 TimeCreated, Id, ProviderName, LevelDisplayName, Message

    if (-not $events) {
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsEventLog' -ResultName 'SystemCriticalError' -ResultKey 'WindowsEventLog|SystemCriticalError' `
            -ExpectedValue 'No Critical/Error events' -ActualValue 'No Critical/Error events found' -ValidationStatus 'PASS' `
            -Details @{ LookbackMinutes = $lookback; LogName = 'System' }
        return
    }

    foreach ($event in $events) {
        $key = 'WindowsEventLog|{0}|{1:yyyyMMddHHmmss}' -f $event.Id, $event.TimeCreated
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsEventLog' -ResultName $event.ProviderName -ResultKey $key `
            -ExpectedValue 'No Critical/Error events' -ActualValue $event.LevelDisplayName -ValidationStatus 'WARN' `
            -Details $event
    }
}

function Invoke-SQLBuildVersionValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $query = @"
SELECT
    @@SERVERNAME AS ServerName,
    CAST(SERVERPROPERTY('ProductVersion') AS varchar(50)) AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel') AS varchar(50)) AS ProductLevel,
    CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(50)) AS ProductUpdateLevel,
    CAST(SERVERPROPERTY('Edition') AS varchar(200)) AS Edition,
    @@VERSION AS FullVersion;
"@

    $rows = Invoke-TargetQuery -ServerInstance $ServerName -Query $query -CommandTimeoutSeconds $Config.CommandTimeoutSeconds -ConnectionTimeoutSeconds $Config.SqlConnectionTimeoutSeconds -TrustServerCertificate $Config.TrustServerCertificate
    foreach ($row in $rows) {
        $actual = '{0} {1} {2}' -f $row.ProductVersion, $row.ProductLevel, $row.ProductUpdateLevel
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'SQLBuildVersion' -ResultName 'SQLBuild' -ResultKey 'SQLBuildVersion|SQLBuild' `
            -ExpectedValue 'Capture build for PRE/POST comparison' -ActualValue $actual -ValidationStatus 'INFO' `
            -Details $row
    }
}

function Invoke-WindowsPatchHistoryValidation {
    param([int]$CurrentRunId, [string]$ServerName, $Config)

    $count = if ($Config.WindowsPatchHistoryCount) { [int]$Config.WindowsPatchHistoryCount } else { 5 }
    $patches = Get-HotFix -ComputerName $ServerName -ErrorAction Stop |
        Sort-Object InstalledOn -Descending |
        Select-Object -First $count HotFixID, Description, InstalledBy, InstalledOn

    foreach ($patch in $patches) {
        $key = 'WindowsPatchHistory|{0}' -f $patch.HotFixID
        Write-ValidationResult -Config $Config -RunId $CurrentRunId -ServerName $ServerName `
            -ValidationType 'WindowsPatchHistory' -ResultName $patch.HotFixID -ResultKey $key `
            -ExpectedValue 'Capture latest installed KB for PRE/POST comparison' -ActualValue $patch.Description -ValidationStatus 'INFO' `
            -Details $patch
    }
}

$config = Get-ValidationConfig -Path $ConfigPath
$effectiveValidationTimeoutSeconds = if ($ValidationTimeoutSeconds -gt 0) { $ValidationTimeoutSeconds } elseif ($config.ValidationTimeoutSeconds) { [int]$config.ValidationTimeoutSeconds } else { 90 }
$logFile = Initialize-ValidationLog -LogRoot $config.LogRoot -Stage $Stage -PatchBatchId $PatchBatchId
Write-ValidationLog -Message "SQL patch validation started. Stage=$Stage PatchBatchId=$PatchBatchId LogFile=$logFile"

try {
    if ($Worker -and -not $RunId) {
        throw 'Worker mode requires -RunId.'
    }

    if ($Worker -and -not $ServerName) {
        throw 'Worker mode requires -ServerName.'
    }

    if ($ServerName) {
        $servers = @($ServerName)
    }
    else {
        $servers = @(Get-ValidationServers -ServerListFile $config.ServerListFile)
    }

    if (-not $ValidationTypes -or $ValidationTypes.Count -eq 0) {
        $ValidationTypes = @($config.ValidationTypes)
    }

    if (-not $RunId) {
        $RunId = New-ValidationRun -Config $config -Stage $Stage -PatchBatchId $PatchBatchId -TotalServers $servers.Count
    }

    Write-ValidationLog -Message "ValidationRun created. RunId=$RunId TotalServers=$($servers.Count)"

    foreach ($server in $servers) {
        foreach ($validationType in $ValidationTypes) {
            Write-ValidationLog -Message 'Starting validation.' -ServerName $server -ValidationType $validationType

            try {
                if (-not $Worker -and -not $DisableIsolation) {
                    Invoke-ValidationChildProcess -CurrentRunId $RunId -CurrentServerName $server -CurrentValidationType $validationType -Config $config -TimeoutSeconds $effectiveValidationTimeoutSeconds
                    continue
                }

                Invoke-WithRetry -RetryCount $config.RetryCount -RetryDelaySeconds $config.RetryDelaySeconds -OperationName "$validationType on $server" -ScriptBlock {
                    switch ($validationType) {
                        'ServerStatus' { Invoke-ServerStatusValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'SQLServices' { Invoke-SQLServicesValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'WindowsServices' { Invoke-WindowsServicesValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'DatabaseStatus' { Invoke-DatabaseStatusValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'FailedAgentJobs' { Invoke-FailedAgentJobsValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'MirroringStatus' { Invoke-MirroringStatusValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'LogShippingStatus' { Invoke-LogShippingStatusValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'ReplicationJobs' { Invoke-ReplicationJobsValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'AvailabilityGroupStatus' { Invoke-AvailabilityGroupStatusValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'WindowsClusterStatus' { Invoke-WindowsClusterStatusValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'SqlErrorLogSeverity' { Invoke-SqlErrorLogSeverityValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'WindowsEventLog' { Invoke-WindowsEventLogValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'SQLBuildVersion' { Invoke-SQLBuildVersionValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        'WindowsPatchHistory' { Invoke-WindowsPatchHistoryValidation -CurrentRunId $RunId -ServerName $server -Config $config }
                        default { throw "Unknown validation type: $validationType" }
                    }
                }
            }
            catch {
                Write-ValidationLog -Level ERROR -Message 'Validation failed.' -ServerName $server -ValidationType $validationType -Exception $_.Exception
                Write-ValidationResult -Config $config -RunId $RunId -ServerName $server `
                    -ValidationType $validationType -ResultName 'CollectorFailure' -ResultKey "$validationType|CollectorFailure" `
                    -ExpectedValue 'Success' -ActualValue $_.Exception.Message -ValidationStatus 'ERROR' `
                    -Details @{ Error = $_.Exception.Message; Stage = $Stage }
            }
        }
    }

    if (-not $Worker) {
        Complete-ValidationRun -Config $config -RunId $RunId -Status 'SUCCESS' -Message "Validation completed. LogFile=$logFile"
        Write-ValidationLog -Message "SQL patch validation completed. RunId=$RunId"
        Write-Output $RunId
    }
}
catch {
    Write-ValidationLog -Level ERROR -Message 'SQL patch validation failed.' -Exception $_.Exception
    if ($RunId -and -not $Worker) {
        Complete-ValidationRun -Config $config -RunId $RunId -Status 'FAILED' -Message $_.Exception.Message
    }
    throw
}
