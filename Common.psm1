function Get-ValidationConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

function Get-ValidationServers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerListFile)

    if (-not (Test-Path -Path $ServerListFile -PathType Leaf)) {
        throw "Server list file not found: $ServerListFile"
    }

    Get-Content -Path $ServerListFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        Sort-Object -Unique
}

function New-RepositoryConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $connectionString = "Data Source=$ServerInstance;Initial Catalog=$DatabaseName;Integrated Security=SSPI;Application Name=SQLPatchValidation"
    return New-Object System.Data.SqlClient.SqlConnection($connectionString)
}

function Invoke-RepositoryScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$CommandText,
        [hashtable]$Parameters = @{},
        [int]$CommandTimeoutSeconds = 120
    )

    $connection = New-RepositoryConnection -ServerInstance $ServerInstance -DatabaseName $DatabaseName
    $command = New-Object System.Data.SqlClient.SqlCommand($CommandText, $connection)
    $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($key in $Parameters.Keys) {
        [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
    }

    try {
        $connection.Open()
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-RepositoryNonQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$CommandText,
        [hashtable]$Parameters = @{},
        [int]$CommandTimeoutSeconds = 120
    )

    $connection = New-RepositoryConnection -ServerInstance $ServerInstance -DatabaseName $DatabaseName
    $command = New-Object System.Data.SqlClient.SqlCommand($CommandText, $connection)
    $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($key in $Parameters.Keys) {
        [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
    }

    try {
        $connection.Open()
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$RetryCount = 2,
        [int]$RetryDelaySeconds = 10,
        [string]$OperationName = 'Operation'
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $attempt++
            if ($attempt -gt $RetryCount) {
                throw
            }
            Write-ValidationLog -Level WARN -Message ("{0} failed. Retry {1}/{2} in {3}s." -f $OperationName, $attempt, $RetryCount, $RetryDelaySeconds) -Exception $_.Exception
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function New-ValidationRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('PRE','POST')]$Stage,
        [Parameter(Mandatory)][string]$PatchBatchId,
        [Parameter(Mandatory)][int]$TotalServers
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $hostName = $env:COMPUTERNAME
    $commandText = @"
EXEC dbo.usp_ValidationRun_Start
    @PatchBatchId = @PatchBatchId,
    @Stage = @Stage,
    @ExecutedBy = @ExecutedBy,
    @ExecutionHost = @ExecutionHost,
    @TotalServers = @TotalServers;
"@

    return [int](Invoke-RepositoryScalar `
        -ServerInstance $Config.RepositoryServer `
        -DatabaseName $Config.RepositoryDatabase `
        -CommandText $commandText `
        -CommandTimeoutSeconds $Config.CommandTimeoutSeconds `
        -Parameters @{
            '@PatchBatchId' = $PatchBatchId
            '@Stage' = $Stage
            '@ExecutedBy' = $identity
            '@ExecutionHost' = $hostName
            '@TotalServers' = $TotalServers
        })
}

function Complete-ValidationRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$RunId,
        [Parameter(Mandatory)][ValidateSet('SUCCESS','FAILED','COMPLETED_WITH_WARNINGS')]$Status,
        [string]$Message
    )

    Invoke-RepositoryNonQuery `
        -ServerInstance $Config.RepositoryServer `
        -DatabaseName $Config.RepositoryDatabase `
        -CommandTimeoutSeconds $Config.CommandTimeoutSeconds `
        -CommandText 'EXEC dbo.usp_ValidationRun_Complete @RunId=@RunId, @Status=@Status, @Message=@Message;' `
        -Parameters @{
            '@RunId' = $RunId
            '@Status' = $Status
            '@Message' = $(if ($Message) { $Message } else { [DBNull]::Value })
        }
}

function Write-ValidationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$RunId,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$ValidationType,
        [Parameter(Mandatory)][string]$ResultName,
        [Parameter(Mandatory)][string]$ResultKey,
        [string]$ExpectedValue,
        [string]$ActualValue,
        [Parameter(Mandatory)][ValidateSet('PASS','FAIL','WARN','INFO','ERROR')]$ValidationStatus,
        [object]$Details
    )

    $detailsJson = $null
    if ($null -ne $Details) {
        $detailsJson = $Details | ConvertTo-Json -Depth 8 -Compress
    }

    Invoke-RepositoryNonQuery `
        -ServerInstance $Config.RepositoryServer `
        -DatabaseName $Config.RepositoryDatabase `
        -CommandTimeoutSeconds $Config.CommandTimeoutSeconds `
        -CommandText @"
EXEC dbo.usp_ValidationResult_Insert
    @RunId=@RunId,
    @ServerName=@ServerName,
    @ValidationType=@ValidationType,
    @ResultName=@ResultName,
    @ResultKey=@ResultKey,
    @ExpectedValue=@ExpectedValue,
    @ActualValue=@ActualValue,
    @ValidationStatus=@ValidationStatus,
    @DetailsJson=@DetailsJson;
"@ `
        -Parameters @{
            '@RunId' = $RunId
            '@ServerName' = $ServerName
            '@ValidationType' = $ValidationType
            '@ResultName' = $ResultName
            '@ResultKey' = $ResultKey
            '@ExpectedValue' = $(if ($ExpectedValue) { $ExpectedValue } else { [DBNull]::Value })
            '@ActualValue' = $(if ($ActualValue) { $ActualValue } else { [DBNull]::Value })
            '@ValidationStatus' = $ValidationStatus
            '@DetailsJson' = $(if ($detailsJson) { $detailsJson } else { [DBNull]::Value })
        }
}

function Invoke-TargetQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Query,
        [string]$DatabaseName = 'master',
        [int]$CommandTimeoutSeconds = 120,
        [int]$ConnectionTimeoutSeconds = 5,
        [bool]$TrustServerCertificate = $false
    )

    $invokeParams = @{
        ServerInstance = $ServerInstance
        Database = $DatabaseName
        Query = $Query
        QueryTimeout = $CommandTimeoutSeconds
        ConnectionTimeout = $ConnectionTimeoutSeconds
        ErrorAction = 'Stop'
    }

    if ($TrustServerCertificate) {
        $invokeParams.TrustServerCertificate = $true
    }

    Invoke-Sqlcmd @invokeParams
}

Export-ModuleMember -Function Get-ValidationConfig, Get-ValidationServers, Invoke-WithRetry, New-ValidationRun, Complete-ValidationRun, Write-ValidationResult, Invoke-TargetQuery, Invoke-RepositoryNonQuery, Invoke-RepositoryScalar
