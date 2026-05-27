[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PRE','POST')]
    [string]$Stage,

    [Parameter(Mandatory)]
    [string]$PatchBatchId,

    [ValidateSet('PATCH','FAST','FULL')]
    [string]$Mode = 'PATCH',

    [string]$FrameworkRoot = 'C:\temp\Phase1_RunID_Framework',

    [string]$RawServerListFile = 'C:\temp\PatchingServers.txt',

    [string]$ValidatedServerListFile = 'C:\temp\PatchingServers.Validated.txt',

    [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor $Color
}

$preflightScript = Join-Path -Path $FrameworkRoot -ChildPath 'Scripts\Invoke-ProductionPreflight.ps1'
$validationScript = Join-Path -Path $FrameworkRoot -ChildPath 'Scripts\Invoke-Validation.ps1'
switch ($Mode) {
    'PATCH' { $configFileName = 'settings.production.patch.json' }
    'FAST' { $configFileName = 'settings.production.fast.json' }
    'FULL' { $configFileName = 'settings.production.full.json' }
}
$configPath = Join-Path -Path $FrameworkRoot -ChildPath $configFileName

if (-not (Test-Path -Path $validationScript -PathType Leaf)) {
    throw "Validation script not found: $validationScript"
}

if (-not (Test-Path -Path $configPath -PathType Leaf)) {
    throw "Config file not found: $configPath"
}

if (-not $SkipPreflight) {
    if (-not (Test-Path -Path $preflightScript -PathType Leaf)) {
        throw "Preflight script not found: $preflightScript"
    }

    Write-Step "Running SQL connectivity preflight for $Mode mode"
    PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $preflightScript `
        -FrameworkRoot $FrameworkRoot `
        -ServerListFile $RawServerListFile `
        -ValidatedServerListFile $ValidatedServerListFile `
        -PatchBatchId "$PatchBatchId-PREFLIGHT"
}

if (-not (Test-Path -Path $ValidatedServerListFile -PathType Leaf)) {
    throw "Validated server list not found: $ValidatedServerListFile"
}

$validatedServers = @(Get-Content -Path $ValidatedServerListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($validatedServers.Count -eq 0) {
    throw "Validated server list is empty: $ValidatedServerListFile"
}

Write-Step "Running $Stage validation. Mode=$Mode PatchBatchId=$PatchBatchId Servers=$($validatedServers.Count)"
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $validationScript `
    -Stage $Stage `
    -PatchBatchId $PatchBatchId `
    -ConfigPath $configPath

Write-Step 'Validation command completed' 'Green'
