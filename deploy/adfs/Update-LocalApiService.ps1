param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\adfs\adfs-local-api.config.psd1",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    return (Join-Path $repoRoot $Path)
}

$setupScriptPath = Join-Path $PSScriptRoot "Setup-LocalApiService.ps1"
if (-not (Test-Path $setupScriptPath)) {
    throw "Setup script not found: $setupScriptPath"
}

$configFullPath = Resolve-RepoPath $ConfigPath
if (-not (Test-Path $configFullPath)) {
    throw "Config file not found: $configFullPath"
}

Write-Host "Updating local API service using config: $configFullPath"

$setupParams = @{ ConfigPath = $configFullPath }
if ($DryRun) {
    $setupParams["DryRun"] = $true
}

& $setupScriptPath @setupParams

Write-Host "Local API service update completed."