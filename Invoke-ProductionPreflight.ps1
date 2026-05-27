[CmdletBinding()]
param(
    [string]$FrameworkRoot = 'C:\temp\Phase1_RunID_Framework',
    [string]$ServerListFile = 'C:\temp\PatchingServers.txt',
    [string]$ValidatedServerListFile = 'C:\temp\PatchingServers.Validated.txt',
    [string]$PatchBatchId = 'SMOKE-PREFLIGHT',
    [switch]$RunFrameworkSmoke
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor $Color
}

function Import-SqlServerModule {
    Write-Step 'Checking SqlServer PowerShell module'

    $modulePaths = @(
        'C:\Program Files\WindowsPowerShell\Modules\SqlServer',
        "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\SqlServer"
    )

    foreach ($path in $modulePaths) {
        if (Test-Path -Path $path) {
            Write-Host "Unblocking module files: $path"
            Get-ChildItem -Path $path -Recurse -File | ForEach-Object {
                try { Unblock-File -Path $_.FullName } catch { }
            }
        }
    }

    Import-Module SqlServer -Force -ErrorAction Stop

    $cmd = Get-Command Invoke-Sqlcmd -ErrorAction Stop
    Write-Host "Invoke-Sqlcmd found: $($cmd.Source)" -ForegroundColor Green
}

function Test-SqlInstance {
    param([Parameter(Mandatory)][string]$ServerInstance)

    try {
        $row = Invoke-Sqlcmd `
            -ServerInstance $ServerInstance `
            -Database master `
            -Query "SELECT @@SERVERNAME AS ServerName, CAST(SERVERPROPERTY('ProductVersion') AS varchar(50)) AS ProductVersion;" `
            -ConnectionTimeout 5 `
            -QueryTimeout 30 `
            -TrustServerCertificate `
            -ErrorAction Stop

        [pscustomobject]@{
            InputName = $ServerInstance
            Status = 'PASS'
            ServerName = $row.ServerName
            ProductVersion = $row.ProductVersion
            Error = $null
        }
    }
    catch {
        [pscustomobject]@{
            InputName = $ServerInstance
            Status = 'FAIL'
            ServerName = $null
            ProductVersion = $null
            Error = $_.Exception.Message
        }
    }
}

Write-Step 'SQL patch validation production preflight started'

if (-not (Test-Path -Path $ServerListFile -PathType Leaf)) {
    throw "Server list file not found: $ServerListFile"
}

Import-SqlServerModule

Write-Step 'Reading server list'
$servers = Get-Content -Path $ServerListFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    Sort-Object -Unique

if (-not $servers) {
    throw "No servers found in $ServerListFile"
}

Write-Host "Servers found: $($servers.Count)"

Write-Step 'Testing SQL connectivity with TrustServerCertificate'
$results = foreach ($server in $servers) {
    Write-Host "Testing $server ..."
    Test-SqlInstance -ServerInstance $server
}

$results | Format-Table -AutoSize

$passed = @($results | Where-Object { $_.Status -eq 'PASS' })
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })

Write-Step 'Writing validated server list'
if ($passed.Count -gt 0) {
    $folder = Split-Path -Path $ValidatedServerListFile -Parent
    if ($folder -and -not (Test-Path -Path $folder -PathType Container)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    $passed.InputName | Set-Content -Path $ValidatedServerListFile -Encoding ascii
    Write-Host "Validated SQL server list written to: $ValidatedServerListFile" -ForegroundColor Green
}
else {
    Write-Host "No SQL instances passed connectivity. Framework SQL checks should not be run yet." -ForegroundColor Red
}

if ($failed.Count -gt 0) {
    Write-Step 'Failed SQL connectivity details' 'Yellow'
    $failed | Select-Object InputName, Error | Format-List
}

if ($RunFrameworkSmoke) {
    Write-Step 'Running framework smoke test'

    $settingsPath = Join-Path -Path $FrameworkRoot -ChildPath 'settings.fast.json'
    $scriptPath = Join-Path -Path $FrameworkRoot -ChildPath 'Scripts\Invoke-Validation.ps1'

    if (-not (Test-Path -Path $settingsPath -PathType Leaf)) {
        throw "settings.fast.json not found: $settingsPath"
    }

    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
        throw "Invoke-Validation.ps1 not found: $scriptPath"
    }

    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    $settings.ServerListFile = $ValidatedServerListFile
    $settings.TrustServerCertificate = $true
    $settings.RetryCount = 0
    $settings.CommandTimeoutSeconds = 30
    $settings.SqlConnectionTimeoutSeconds = 5
    $settings.ValidationTimeoutSeconds = 45
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8

    PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Stage PRE -PatchBatchId $PatchBatchId -ConfigPath $settingsPath
}

Write-Step 'Preflight complete' 'Green'
