param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\web\web-node.config.psd1",

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
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

function Escape-Psd1String {
    param([string]$Value)
    return ($Value -replace "'", "''")
}

function Write-ConfigFile {
    param(
        [string]$Path,
        [hashtable]$Config
    )

    $content = @"
@{
    ApiZipPath = '$(Escape-Psd1String $Config.ApiZipPath)'
    EnrollmentZipPath = '$(Escape-Psd1String $Config.EnrollmentZipPath)'
    AdminZipPath = '$(Escape-Psd1String $Config.AdminZipPath)'
    SiteRoot = '$(Escape-Psd1String $Config.SiteRoot)'

    ApiHost = '$(Escape-Psd1String $Config.ApiHost)'
    EnrollmentHost = '$(Escape-Psd1String $Config.EnrollmentHost)'
    AdminHost = '$(Escape-Psd1String $Config.AdminHost)'
    CertificateThumbprint = '$(Escape-Psd1String $Config.CertificateThumbprint)'

    SqlServer = '$(Escape-Psd1String $Config.SqlServer)'
    SqlDatabase = '$(Escape-Psd1String $Config.SqlDatabase)'
    UseIntegratedSecurity = `$$($Config.UseIntegratedSecurity)
    SqlUser = '$(Escape-Psd1String $Config.SqlUser)'
    SqlPassword = '$(Escape-Psd1String $Config.SqlPassword)'

    MasterKeyBase64 = '$(Escape-Psd1String $Config.MasterKeyBase64)'
    AdminApiKey = '$(Escape-Psd1String $Config.AdminApiKey)'
}
"@

    $configDir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Set-Content -Path $Path -Value $content -Encoding UTF8
}

function Read-Bool {
    param(
        [string]$Prompt,
        [bool]$Default
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    $raw = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    return @("y", "yes", "o", "oui", "1", "true") -contains $raw.Trim().ToLowerInvariant()
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

function Build-ConnectionString {
    param([hashtable]$Config)

    if ($Config.UseIntegratedSecurity) {
        return "Server=$($Config.SqlServer);Database=$($Config.SqlDatabase);Integrated Security=true;TrustServerCertificate=true;"
    }

    return "Server=$($Config.SqlServer);Database=$($Config.SqlDatabase);User Id=$($Config.SqlUser);Password=$($Config.SqlPassword);TrustServerCertificate=true;"
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

function Ensure-IIS {
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        Install-WindowsFeature Web-Server,Web-WebServer,Web-Common-Http,Web-Static-Content,Web-Default-Doc,Web-Http-Errors,Web-Health,Web-Http-Logging,Web-Performance,Web-Stat-Compression,Web-Security,Web-Filtering,Web-App-Dev,Web-Net-Ext45,Web-Asp-Net45,Web-ISAPI-Ext,Web-ISAPI-Filter,Web-Mgmt-Tools -IncludeManagementTools | Out-Null
    }
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Administrator)."
}

$configFullPath = Resolve-RepoPath $ConfigPath
$configExists = Test-Path $configFullPath

if ($Interactive -or -not $configExists) {
    Write-Host "Interactive setup for web/IIS OTP node"

    $apiZipPath = Read-Host "API ZIP path"
    $enrollmentZipPath = Read-Host "Enrollment portal ZIP path"
    $adminZipPath = Read-Host "Admin portal ZIP path"

    $siteRoot = Read-Host "Site root folder"; if ([string]::IsNullOrWhiteSpace($siteRoot)) { $siteRoot = "C:\inetpub\freeadfsotp" }

    $apiHost = Read-Host "API host"; if ([string]::IsNullOrWhiteSpace($apiHost)) { throw "ApiHost is required." }
    $enrollmentHost = Read-Host "Enrollment host"; if ([string]::IsNullOrWhiteSpace($enrollmentHost)) { throw "EnrollmentHost is required." }
    $adminHost = Read-Host "Admin host"; if ([string]::IsNullOrWhiteSpace($adminHost)) { throw "AdminHost is required." }

    $certificateThumbprint = Read-Host "TLS certificate thumbprint (LocalMachine\\My)"
    if ([string]::IsNullOrWhiteSpace($certificateThumbprint)) { throw "CertificateThumbprint is required." }

    $sqlServer = Read-Host "SQL server"
    $sqlDatabase = Read-Host "SQL database"; if ([string]::IsNullOrWhiteSpace($sqlDatabase)) { $sqlDatabase = "FreeAdfsOtp" }
    $useIntegratedSecurity = Read-Bool -Prompt "Use integrated security for SQL" -Default $true

    $sqlUser = ""
    $sqlPassword = ""
    if (-not $useIntegratedSecurity) {
        $sqlUser = Read-Host "SQL user"
        $sqlPassword = Read-Host "SQL password (stored in plain text in config)"
    }

    $masterKeyBase64 = Read-Host "API SecretProtection:MasterKey (base64 32 bytes)"
    $adminApiKey = Read-Host "Admin API key (same value for API and admin portal)"

    $config = @{
        ApiZipPath = $apiZipPath
        EnrollmentZipPath = $enrollmentZipPath
        AdminZipPath = $adminZipPath
        SiteRoot = $siteRoot
        ApiHost = $apiHost
        EnrollmentHost = $enrollmentHost
        AdminHost = $adminHost
        CertificateThumbprint = $certificateThumbprint
        SqlServer = $sqlServer
        SqlDatabase = $sqlDatabase
        UseIntegratedSecurity = $useIntegratedSecurity
        SqlUser = $sqlUser
        SqlPassword = $sqlPassword
        MasterKeyBase64 = $masterKeyBase64
        AdminApiKey = $adminApiKey
    }

    Write-ConfigFile -Path $configFullPath -Config $config
    Write-Host "Config saved: $configFullPath"
}

$config = Import-PowerShellDataFile -Path $configFullPath

$apiZipPath = Resolve-RepoPath $config.ApiZipPath
$enrollmentZipPath = Resolve-RepoPath $config.EnrollmentZipPath
$adminZipPath = Resolve-RepoPath $config.AdminZipPath

foreach ($zip in @($apiZipPath, $enrollmentZipPath, $adminZipPath)) {
    if (-not (Test-Path $zip)) {
        throw "ZIP not found: $zip"
    }
}

$siteRoot = $config.SiteRoot
$apiPath = Join-Path $siteRoot "api"
$enrollmentPath = Join-Path $siteRoot "enrollment"
$adminPath = Join-Path $siteRoot "admin"

Invoke-IfNotDryRun -Description "Install IIS features" -Action {
    Ensure-IIS
}

Invoke-IfNotDryRun -Description "Extract web ZIPs" -Action {
    foreach ($path in @($apiPath, $enrollmentPath, $adminPath)) {
        if (Test-Path $path) {
            Remove-Item -Recurse -Force $path
        }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    Expand-Archive -Path $apiZipPath -DestinationPath $apiPath -Force
    Expand-Archive -Path $enrollmentZipPath -DestinationPath $enrollmentPath -Force
    Expand-Archive -Path $adminZipPath -DestinationPath $adminPath -Force
}

$apiSettingsPath = Join-Path $apiPath "appsettings.json"
$enrollmentSettingsPath = Join-Path $enrollmentPath "appsettings.json"
$adminSettingsPath = Join-Path $adminPath "appsettings.json"

if (-not (Test-Path $apiSettingsPath)) { throw "Missing appsettings.json in API package." }
if (-not (Test-Path $enrollmentSettingsPath)) { throw "Missing appsettings.json in enrollment package." }
if (-not (Test-Path $adminSettingsPath)) { throw "Missing appsettings.json in admin package." }

$apiBaseUrl = "https://$($config.ApiHost)"
$connectionString = Build-ConnectionString -Config $config

Invoke-IfNotDryRun -Description "Write API and portal appsettings" -Action {
    Update-JsonFile -Path $apiSettingsPath -Update {
        param($json)
        $json.ConnectionStrings.OtpSql = $connectionString
        $json.SecretProtection.MasterKey = $config.MasterKeyBase64
        $json.AdminAuth.ApiKey = $config.AdminApiKey
    }

    Update-JsonFile -Path $enrollmentSettingsPath -Update {
        param($json)
        $json.OtpApi.BaseUrl = $apiBaseUrl
    }

    Update-JsonFile -Path $adminSettingsPath -Update {
        param($json)
        $json.OtpApi.BaseUrl = $apiBaseUrl
        $json.OtpApi.AdminApiKey = $config.AdminApiKey
    }
}

Invoke-IfNotDryRun -Description "Configure IIS sites and app pools" -Action {
    Import-Module WebAdministration

    $sites = @(
        @{ Name = "freeADFSOtp-Api"; Pool = "freeADFSOtp-ApiPool"; Path = $apiPath; Host = $config.ApiHost },
        @{ Name = "freeADFSOtp-Enrollment"; Pool = "freeADFSOtp-EnrollmentPool"; Path = $enrollmentPath; Host = $config.EnrollmentHost },
        @{ Name = "freeADFSOtp-Admin"; Pool = "freeADFSOtp-AdminPool"; Path = $adminPath; Host = $config.AdminHost }
    )

    foreach ($site in $sites) {
        if (Test-Path "IIS:\AppPools\$($site.Pool)") {
            Remove-WebAppPool -Name $site.Pool
        }

        New-WebAppPool -Name $site.Pool | Out-Null
        Set-ItemProperty "IIS:\AppPools\$($site.Pool)" managedRuntimeVersion ""

        if (Get-Website -Name $site.Name -ErrorAction SilentlyContinue) {
            Remove-Website -Name $site.Name
        }

        New-Website -Name $site.Name -PhysicalPath $site.Path -Port 80 -IPAddress "*" -HostHeader $site.Host -ApplicationPool $site.Pool | Out-Null
        New-WebBinding -Name $site.Name -Protocol https -Port 443 -HostHeader $site.Host | Out-Null

        $sslBindingPath = "IIS:\SslBindings\0.0.0.0!443!$($site.Host)"
        if (Test-Path $sslBindingPath) {
            Remove-Item $sslBindingPath -Force
        }

        New-Item $sslBindingPath -Thumbprint $config.CertificateThumbprint -SSLFlags 1 | Out-Null

        $appPoolIdentity = "IIS AppPool\$($site.Pool)"
        $grantRule = "${appPoolIdentity}:(OI)(CI)RX"
        & icacls $site.Path /grant $grantRule /T | Out-Null
        Start-Website -Name $site.Name
    }
}

Write-Host "Web deployment completed."
Write-Host "Reusable node config: $configFullPath"
