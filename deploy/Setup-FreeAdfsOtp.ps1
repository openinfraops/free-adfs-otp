param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\freeadfsotp.installer.config.psd1",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Validate", "InstallAll", "UpgradeAll")]
    [string]$Action = "Validate",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPolicy,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSql,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeWeb
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RepoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    return (Join-Path $repoRoot $Path)
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Name,
        $DefaultValue
    )

    if ($Config.ContainsKey($Name) -and $null -ne $Config[$Name]) {
        return $Config[$Name]
    }

    return $DefaultValue
}

function Assert-PathExists {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path $Path)) {
        throw "$Description not found: $Path"
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    Assert-PathExists -Path $ScriptPath -Description "Script"

    Write-Host ""
    Write-Host "=== $Name ==="
    & $ScriptPath @Parameters
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Administrator)."
}

$configFullPath = Resolve-RepoPath $ConfigPath
Assert-PathExists -Path $configFullPath -Description "Installer config"

$config = Import-PowerShellDataFile -Path $configFullPath

$adfsConfigPath = Resolve-RepoPath (Get-ConfigValue -Config $config -Name "AdfsConfigPath" -DefaultValue "")
$localApiConfigPath = Resolve-RepoPath (Get-ConfigValue -Config $config -Name "LocalApiConfigPath" -DefaultValue "")
$webConfigPath = Resolve-RepoPath (Get-ConfigValue -Config $config -Name "WebConfigPath" -DefaultValue "")
$sqlServer = [string](Get-ConfigValue -Config $config -Name "SqlServer" -DefaultValue "")
$sqlDatabase = [string](Get-ConfigValue -Config $config -Name "SqlDatabase" -DefaultValue "FreeAdfsOtp")
$useIntegratedSecurity = [bool](Get-ConfigValue -Config $config -Name "UseIntegratedSecurity" -DefaultValue $true)
$sqlUser = [string](Get-ConfigValue -Config $config -Name "SqlUser" -DefaultValue "")
$sqlPassword = [string](Get-ConfigValue -Config $config -Name "SqlPassword" -DefaultValue "")
$sqlScriptsRoot = Resolve-RepoPath (Get-ConfigValue -Config $config -Name "SqlScriptsRoot" -DefaultValue ".\sql")

$setupAdfsScript = Join-Path $PSScriptRoot "adfs\Setup-AdfsOtpNode.ps1"
$updateAdfsScript = Join-Path $PSScriptRoot "adfs\Update-AdfsConnector.ps1"
$setupLocalApiScript = Join-Path $PSScriptRoot "adfs\Setup-LocalApiService.ps1"
$updateLocalApiScript = Join-Path $PSScriptRoot "adfs\Update-LocalApiService.ps1"
$setupWebScript = Join-Path $PSScriptRoot "web\Setup-WebOtpNode.ps1"
$updateWebScript = Join-Path $PSScriptRoot "web\Update-EnrollmentPortal.ps1"
$sqlInitScript = Join-Path $PSScriptRoot "sql\Initialize-FreeAdfsOtpSql.ps1"

Assert-PathExists -Path $adfsConfigPath -Description "ADFS config"
Assert-PathExists -Path $localApiConfigPath -Description "Local API config"

if ($IncludeWeb) {
    Assert-PathExists -Path $webConfigPath -Description "Web config"
}

if (($Action -eq "InstallAll" -or $Action -eq "UpgradeAll") -and -not $SkipSql -and [string]::IsNullOrWhiteSpace($sqlServer)) {
    throw "SqlServer is required in installer config when SQL step is enabled."
}

if (($Action -eq "InstallAll" -or $Action -eq "UpgradeAll") -and -not $SkipSql -and -not $useIntegratedSecurity) {
    if ([string]::IsNullOrWhiteSpace($sqlUser) -or [string]::IsNullOrWhiteSpace($sqlPassword)) {
        throw "SqlUser and SqlPassword are required when UseIntegratedSecurity is false."
    }
}

if ($Action -eq "Validate") {
    Assert-PathExists -Path $setupAdfsScript -Description "ADFS install script"
    Assert-PathExists -Path $updateAdfsScript -Description "ADFS upgrade script"
    Assert-PathExists -Path $setupLocalApiScript -Description "Local API install script"
    Assert-PathExists -Path $updateLocalApiScript -Description "Local API upgrade script"
    Assert-PathExists -Path $sqlInitScript -Description "SQL init script"

    if ($IncludeWeb) {
        Assert-PathExists -Path $setupWebScript -Description "Web install script"
        Assert-PathExists -Path $updateWebScript -Description "Web upgrade script"
    }

    if (-not $SkipSql) {
        $sqlValidateParams = @{
            SqlServer = $sqlServer
            SqlDatabase = $sqlDatabase
            UseIntegratedSecurity = $useIntegratedSecurity
            SqlUser = $sqlUser
            SqlPassword = $sqlPassword
            ScriptsRoot = $sqlScriptsRoot
            DryRun = $true
        }

        Invoke-Step -Name "Validate SQL initialization prerequisites" -ScriptPath $sqlInitScript -Parameters $sqlValidateParams
    }

    Write-Host ""
    Write-Host "Validation completed successfully."
    exit 0
}

if (-not $SkipSql) {
    $sqlParams = @{
        SqlServer = $sqlServer
        SqlDatabase = $sqlDatabase
        UseIntegratedSecurity = $useIntegratedSecurity
        SqlUser = $sqlUser
        SqlPassword = $sqlPassword
        ScriptsRoot = $sqlScriptsRoot
        DryRun = $DryRun
    }

    Invoke-Step -Name "Initialize SQL" -ScriptPath $sqlInitScript -Parameters $sqlParams
}

if ($Action -eq "InstallAll") {
    $adfsInstallParams = @{
        ConfigPath = $adfsConfigPath
        SkipPolicy = $SkipPolicy
        DryRun = $DryRun
    }

    $localApiInstallParams = @{
        ConfigPath = $localApiConfigPath
        DryRun = $DryRun
    }

    Invoke-Step -Name "Install ADFS connector" -ScriptPath $setupAdfsScript -Parameters $adfsInstallParams
    Invoke-Step -Name "Install local API" -ScriptPath $setupLocalApiScript -Parameters $localApiInstallParams

    if ($IncludeWeb) {
        $webInstallParams = @{
            ConfigPath = $webConfigPath
            DryRun = $DryRun
        }

        Invoke-Step -Name "Install web/admin stack" -ScriptPath $setupWebScript -Parameters $webInstallParams
    }
}
elseif ($Action -eq "UpgradeAll") {
    $adfsUpgradeParams = @{
        ConfigPath = $adfsConfigPath
        DryRun = $DryRun
    }

    $localApiUpgradeParams = @{
        ConfigPath = $localApiConfigPath
        DryRun = $DryRun
    }

    Invoke-Step -Name "Upgrade ADFS connector" -ScriptPath $updateAdfsScript -Parameters $adfsUpgradeParams
    Invoke-Step -Name "Upgrade local API" -ScriptPath $updateLocalApiScript -Parameters $localApiUpgradeParams

    if ($IncludeWeb) {
        $webUpgradeParams = @{
            ConfigPath = $webConfigPath
            DryRun = $DryRun
        }

        Invoke-Step -Name "Upgrade web/admin stack" -ScriptPath $updateWebScript -Parameters $webUpgradeParams
    }
}

Write-Host ""
Write-Host "Global action '$Action' completed successfully."
