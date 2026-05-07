param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$RestartAdfsService,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveFromGac,

    [Parameter(Mandatory = $false)]
    [string]$GacIdentity = '',

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path $Path).Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    return (Resolve-Path (Join-Path $repoRoot $Path)).Path
}

function Invoke-Step {
    param(
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    $scriptFullPath = Resolve-Path $ScriptPath
    $paramDisplay = ($Parameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join " "

    if ($DryRun) {
        Write-Host "[DRY-RUN] & $scriptFullPath $paramDisplay"
        return
    }

    Write-Host "Running: $scriptFullPath"
    & $scriptFullPath @Parameters
}

$configFullPath = Resolve-RepoPath $ConfigPath
$config = Import-PowerShellDataFile -Path $configFullPath

$providerName = $config.ProviderName
if ([string]::IsNullOrWhiteSpace($providerName)) {
    throw "ProviderName missing in config."
}

Invoke-Step -ScriptPath (Join-Path $PSScriptRoot "06-clear-mfa-policy.ps1") -Parameters @{
    ProviderName = $providerName
}

$unregisterParams = @{
    ProviderName = $providerName
}

if ($RestartAdfsService) {
    $unregisterParams["RestartAdfsService"] = $true
}

Invoke-Step -ScriptPath (Join-Path $PSScriptRoot "04-unregister-provider.ps1") -Parameters $unregisterParams

if ($RemoveFromGac) {
    if ([string]::IsNullOrWhiteSpace($GacIdentity)) {
        throw "GacIdentity is required when -RemoveFromGac is used."
    }

    $gacutilPath = $config.GacutilPath
    if ([string]::IsNullOrWhiteSpace($gacutilPath)) {
        throw "GacutilPath missing in config."
    }

    if ($DryRun) {
        Write-Host "[DRY-RUN] & $gacutilPath /u \"$GacIdentity\""
    }
    else {
        & $gacutilPath /u $GacIdentity
    }
}

Write-Host "Rollback workflow completed for provider: $providerName"
