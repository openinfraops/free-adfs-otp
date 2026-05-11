param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\web\web-node.config.psd1",

    [Parameter(Mandatory = $false)]
    [string]$EnrollmentZipPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
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

function Invoke-IfNotDryRun {
    param(
        [scriptblock]$Action,
        [string]$Description
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] $Description"
        return
    }

    & $Action
}

function Ensure-JsonObjectProperty {
    param(
        [object]$Object,
        [string]$PropertyName
    )

    $existing = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $existing -or $null -eq $existing.Value) {
        $Object | Add-Member -MemberType NoteProperty -Name $PropertyName -Value ([pscustomobject]@{}) -Force
    }

    return $Object.PSObject.Properties[$PropertyName].Value
}

function Update-JsonFile {
    param(
        [string]$Path,
        [scriptblock]$Update
    )

    $json = Get-Content $Path -Raw | ConvertFrom-Json
    & $Update $json
    $json | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Set-SiteAuthentication {
    param(
        [string]$SiteName,
        [bool]$EnableWindowsAuthentication,
        [bool]$EnableAnonymousAuthentication
    )

    Set-WebConfigurationProperty -PSPath "IIS:\" -Location $SiteName -Filter "system.webServer/security/authentication/windowsAuthentication" -Name "enabled" -Value $EnableWindowsAuthentication
    Set-WebConfigurationProperty -PSPath "IIS:\" -Location $SiteName -Filter "system.webServer/security/authentication/anonymousAuthentication" -Name "enabled" -Value $EnableAnonymousAuthentication
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Administrator)."
}

$configFullPath = Resolve-RepoPath $ConfigPath
if (-not (Test-Path $configFullPath)) {
    throw "Config file not found: $configFullPath"
}

$config = Import-PowerShellDataFile -Path $configFullPath

$zipPathFromConfig = Resolve-RepoPath $config.EnrollmentZipPath
$resolvedEnrollmentZipPath = if ([string]::IsNullOrWhiteSpace($EnrollmentZipPath)) { $zipPathFromConfig } else { Resolve-RepoPath $EnrollmentZipPath }

if (-not (Test-Path $resolvedEnrollmentZipPath)) {
    throw "Enrollment ZIP not found: $resolvedEnrollmentZipPath"
}

$siteRoot = $config.SiteRoot
$enrollmentPath = Join-Path $siteRoot "enrollment"
$enrollmentSettingsPath = Join-Path $enrollmentPath "appsettings.json"

if (-not (Test-Path $enrollmentPath)) {
    throw "Enrollment path not found: $enrollmentPath"
}

$apiBaseUrl = "https://$($config.ApiHost)"
$enrollmentIdpName = Get-ConfigValue -Config $config -Name "EnrollmentIdpName" -DefaultValue "freeADFSOtp"
$enrollmentPhoneIssuerName = Get-ConfigValue -Config $config -Name "EnrollmentPhoneIssuerName" -DefaultValue $enrollmentIdpName
$enrollmentAllowedWindowsDomain = Get-ConfigValue -Config $config -Name "EnrollmentAllowedWindowsDomain" -DefaultValue ""
$enrollmentDefaultUpnSuffix = Get-ConfigValue -Config $config -Name "EnrollmentDefaultUpnSuffix" -DefaultValue ""
$enrollmentAllowManualUpn = [bool](Get-ConfigValue -Config $config -Name "EnrollmentAllowManualUpn" -DefaultValue $false)
$enrollmentUseWindowsAuthentication = [bool](Get-ConfigValue -Config $config -Name "EnrollmentUseWindowsAuthentication" -DefaultValue $true)
$enrollmentDisableAnonymousAuthentication = [bool](Get-ConfigValue -Config $config -Name "EnrollmentDisableAnonymousAuthentication" -DefaultValue $true)

Invoke-IfNotDryRun -Description "Backup current enrollment portal" -Action {
    if ($SkipBackup) {
        return
    }

    $backupRoot = Join-Path $siteRoot "_backup"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = Join-Path $backupRoot "enrollment-$timestamp"
    Copy-Item -Recurse -Force $enrollmentPath $backupPath
    Write-Host "Backup created: $backupPath"
}

$tempRoot = Join-Path $env:TEMP ("freeadfsotp-enrollment-update-" + [Guid]::NewGuid().ToString("N"))
$tempEnrollmentPath = Join-Path $tempRoot "enrollment"

Invoke-IfNotDryRun -Description "Extract new enrollment portal package" -Action {
    New-Item -ItemType Directory -Path $tempEnrollmentPath -Force | Out-Null
    Expand-Archive -Path $resolvedEnrollmentZipPath -DestinationPath $tempEnrollmentPath -Force
}

$tempSettingsPath = Join-Path $tempEnrollmentPath "appsettings.json"
if (-not (Test-Path $tempSettingsPath)) {
    throw "Missing appsettings.json in enrollment ZIP package."
}

Invoke-IfNotDryRun -Description "Apply enrollment appsettings security configuration" -Action {
    Update-JsonFile -Path $tempSettingsPath -Update {
        param($json)

        $otpApi = Ensure-JsonObjectProperty -Object $json -PropertyName "OtpApi"
        $enrollment = Ensure-JsonObjectProperty -Object $json -PropertyName "Enrollment"

        $otpApi.BaseUrl = $apiBaseUrl
        $enrollment.IdpName = $enrollmentIdpName
    $enrollment.PhoneIssuerName = $enrollmentPhoneIssuerName
        $enrollment.AllowManualUpn = $enrollmentAllowManualUpn
        $enrollment.AllowedWindowsDomain = $enrollmentAllowedWindowsDomain
        $enrollment.DefaultUpnSuffix = $enrollmentDefaultUpnSuffix
    }
}

Invoke-IfNotDryRun -Description "Swap enrollment portal files" -Action {
    Import-Module WebAdministration

    if (-not (Get-Website -Name "freeADFSOtp-Enrollment" -ErrorAction SilentlyContinue)) {
        throw "IIS website 'freeADFSOtp-Enrollment' not found. Run Setup-WebOtpNode.ps1 first."
    }

    Stop-Website -Name "freeADFSOtp-Enrollment"
    if (Test-Path $enrollmentPath) {
        Remove-Item -Recurse -Force $enrollmentPath
    }

    Move-Item -Path $tempEnrollmentPath -Destination $enrollmentPath

    Set-SiteAuthentication -SiteName "freeADFSOtp-Enrollment" -EnableWindowsAuthentication:$enrollmentUseWindowsAuthentication -EnableAnonymousAuthentication:(-not $enrollmentDisableAnonymousAuthentication)
    Start-Website -Name "freeADFSOtp-Enrollment"

    $poolName = "freeADFSOtp-EnrollmentPool"
    if (Test-Path "IIS:\AppPools\$poolName") {
        $appPoolIdentity = "IIS AppPool\$poolName"
        $grantRule = "${appPoolIdentity}:(OI)(CI)RX"
        & icacls $enrollmentPath /grant $grantRule /T | Out-Null
    }
}

Invoke-IfNotDryRun -Description "Clean temporary files" -Action {
    if (Test-Path $tempRoot) {
        Remove-Item -Recurse -Force $tempRoot
    }
}

Write-Host "Enrollment portal update completed."
Write-Host "Config used: $configFullPath"
Write-Host "ZIP used: $resolvedEnrollmentZipPath"