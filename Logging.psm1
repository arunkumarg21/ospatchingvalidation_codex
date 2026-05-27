function Initialize-ValidationLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$PatchBatchId
    )

    $date = Get-Date -Format 'yyyyMMdd'
    $folder = Join-Path -Path $LogRoot -ChildPath $date
    if (-not (Test-Path -Path $folder -PathType Container)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    $script:ValidationLogFile = Join-Path -Path $folder -ChildPath ("PatchValidation_{0}_{1}_{2}.log" -f $Stage, $PatchBatchId, (Get-Date -Format 'HHmmss'))
    return $script:ValidationLogFile
}

function Write-ValidationLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message,
        [string]$ServerName,
        [string]$ValidationType,
        [System.Exception]$Exception
    )

    $parts = @(
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),
        $Level,
        $(if ($ServerName) { $ServerName } else { '-' }),
        $(if ($ValidationType) { $ValidationType } else { '-' }),
        $Message
    )

    if ($Exception) {
        $parts += ("Exception={0}" -f $Exception.Message)
    }

    $line = $parts -join ' | '
    Write-Host $line

    if ($script:ValidationLogFile) {
        $line | Out-File -FilePath $script:ValidationLogFile -Append -Encoding utf8
    }
}

Export-ModuleMember -Function Initialize-ValidationLog, Write-ValidationLog
