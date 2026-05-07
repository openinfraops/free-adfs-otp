param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBuild,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGac,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRegister,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPolicy,

    [Parameter(Mandatory = $false)]
    [switch]$RestartAdfsService
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
$typeName = $config.TypeName
$dotnetPath = $config.DotnetPath
$adfsAssemblyPath = $config.AdfsAssemblyPath
$gacutilPath = $config.GacutilPath
$buildConfiguration = $config.BuildConfiguration
$framework = $config.Framework
$outputPath = $config.OutputPath
$adapterDllPath = Resolve-RepoPath $config.AdapterDllPath
$configurationFilePath = Resolve-RepoPath $config.ConfigurationFilePath

if ([string]::IsNullOrWhiteSpace($providerName)) { throw "ProviderName missing in config." }
if ([string]::IsNullOrWhiteSpace($typeName)) { throw "TypeName missing in config." }

Write-Host "Deploying provider: $providerName"
Write-Host "Config file: $configFullPath"

if (-not $SkipBuild) {
    Invoke-Step -ScriptPath (Join-Path $PSScriptRoot "01-build-adapter.ps1") -Parameters @{
        Configuration = $buildConfiguration
        Framework = $framework
        DotnetPath = $dotnetPath
        ProjectPath = ".\src\FreeAdfsOtp.AdfsAdapter\FreeAdfsOtp.AdfsAdapter.csproj"
        AdfsAssemblyPath = $adfsAssemblyPath
        OutputPath = $outputPath
    }
}

if (-not $SkipGac) {
    Invoke-Step -ScriptPath (Join-Path $PSScriptRoot "02-gac-install.ps1") -Parameters @{
        AdapterDllPath = $adapterDllPath
        GacutilPath = $gacutilPath
    }
}

if (-not $SkipRegister) {
    $registerParams = @{
        ProviderName = $providerName
        TypeName = $typeName
        ConfigurationFilePath = $configurationFilePath
    }

    if ($RestartAdfsService) {
        $registerParams["RestartAdfsService"] = $true
    }

    Invoke-Step -ScriptPath (Join-Path $PSScriptRoot "03-register-provider.ps1") -Parameters $registerParams
}

if (-not $SkipPolicy) {
    $requireExternalOnly = $true
    if ($config.ContainsKey("RequireExternalOnly")) {
        $requireExternalOnly = [bool]$config.RequireExternalOnly
    }

    $applyGlobalRule = $true
    if ($config.ContainsKey("ApplyGlobalRule")) {
        $applyGlobalRule = [bool]$config.ApplyGlobalRule
    }

    Invoke-Step -ScriptPath (Join-Path $PSScriptRoot "05-configure-mfa-policy.ps1") -Parameters @{
        ProviderName = $providerName
        RequireExternalOnly = $requireExternalOnly
        ApplyGlobalRule = $applyGlobalRule
    }
}

Write-Host "Deployment workflow completed for provider: $providerName"
