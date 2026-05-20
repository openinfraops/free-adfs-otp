param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\adfs\adfs-local-api.config.psd1",

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

function ConvertTo-Psd1SafeString {
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
    ApiZipPath = '$(ConvertTo-Psd1SafeString $Config.ApiZipPath)'
    InstallRoot = '$(ConvertTo-Psd1SafeString $Config.InstallRoot)'
    ServiceName = '$(ConvertTo-Psd1SafeString $Config.ServiceName)'
    DotnetPath = '$(ConvertTo-Psd1SafeString $Config.DotnetPath)'
    ListenUrl = '$(ConvertTo-Psd1SafeString $Config.ListenUrl)'

    OtpSqlConnectionString = '$(ConvertTo-Psd1SafeString $Config.OtpSqlConnectionString)'
    MasterKeyBase64 = '$(ConvertTo-Psd1SafeString $Config.MasterKeyBase64)'
    AdminApiKey = '$(ConvertTo-Psd1SafeString $Config.AdminApiKey)'

    LocalCacheEnabled = `$$($Config.LocalCacheEnabled)
    AllowSqlFallbackForValidation = `$$($Config.AllowSqlFallbackForValidation)
    LocalCacheDatabasePath = '$(ConvertTo-Psd1SafeString $Config.LocalCacheDatabasePath)'
    PeriodicSyncEnabled = `$$($Config.PeriodicSyncEnabled)
    PeriodicSyncIntervalSeconds = $($Config.PeriodicSyncIntervalSeconds)

    ServiceAccount = '$(ConvertTo-Psd1SafeString $Config.ServiceAccount)'
    ServiceAccountPassword = '$(ConvertTo-Psd1SafeString $Config.ServiceAccountPassword)'
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

function Invoke-ScExe {
    param(
        [string[]]$Arguments,
        [string]$OperationDescription
    )

    $output = & sc.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $renderedArgs = ($Arguments -join ' ')
        throw "sc.exe failed during '$OperationDescription' (exit code $exitCode). Command: sc.exe $renderedArgs`nOutput:`n$output"
    }

    return $output
}

function Remove-ServiceIfExists {
    param([string]$Name)

    $serviceRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"

    $existingService = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $existingService) {
        return
    }

    if ($existingService.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    $queryExOutput = & sc.exe queryex $Name 2>$null
    if ($LASTEXITCODE -eq 0) {
        $pidLine = $queryExOutput | Where-Object { $_ -match 'PID\s*:\s*\d+' } | Select-Object -First 1
        if ($pidLine -match 'PID\s*:\s*(\d+)') {
            $servicePid = [int]$Matches[1]
            if ($servicePid -gt 0) {
                Stop-Process -Id $servicePid -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Invoke-ScExe -Arguments @('delete', $Name) -OperationDescription "delete service $Name" | Out-Null

    $serviceDeleted = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 500

        $serviceStillPresent = $null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)
        $registryStillPresent = Test-Path $serviceRegistryPath

        if (-not $serviceStillPresent -and -not $registryStillPresent) {
            $serviceDeleted = $true
            break
        }
    }

    if (-not $serviceDeleted) {
        throw "Service '$Name' is still marked for deletion. Close services.msc and any tool querying this service, then retry. If it persists, reboot the node and rerun deployment."
    }
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

function Get-OrAddJsonObjectProperty {
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

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Administrator)."
}

$configFullPath = Resolve-RepoPath $ConfigPath
$configExists = Test-Path $configFullPath

if ($Interactive -or -not $configExists) {
    Write-Host "Interactive setup for local API on AD FS node (no IIS)."

    $apiZipPath = Read-Host "API ZIP path (from package-artifacts output)"
    if ([string]::IsNullOrWhiteSpace($apiZipPath)) { throw "ApiZipPath is required." }

    $installRoot = Read-Host "Install root folder"; if ([string]::IsNullOrWhiteSpace($installRoot)) { $installRoot = "C:\ProgramData\FreeAdfsOtp\Api" }
    $serviceName = Read-Host "Windows service name"; if ([string]::IsNullOrWhiteSpace($serviceName)) { $serviceName = "FreeAdfsOtpApi" }
    $dotnetPath = Read-Host "dotnet.exe path"; if ([string]::IsNullOrWhiteSpace($dotnetPath)) { $dotnetPath = "C:\Program Files\dotnet\dotnet.exe" }
    $listenUrl = Read-Host "Listen URL (local only recommended)"; if ([string]::IsNullOrWhiteSpace($listenUrl)) { $listenUrl = "http://127.0.0.1:5180" }

    $otpSqlConnectionString = Read-Host "ConnectionStrings:OtpSql"
    if ([string]::IsNullOrWhiteSpace($otpSqlConnectionString)) { throw "OtpSqlConnectionString is required." }

    $masterKeyBase64 = Read-Host "SecretProtection:MasterKey (base64 32 bytes)"
    if ([string]::IsNullOrWhiteSpace($masterKeyBase64)) { throw "MasterKeyBase64 is required." }

    $adminApiKey = Read-Host "AdminAuth:ApiKey"
    if ([string]::IsNullOrWhiteSpace($adminApiKey)) { throw "AdminApiKey is required." }

    $localCacheEnabled = Read-Bool -Prompt "Enable local cache" -Default $true
    $allowSqlFallback = Read-Bool -Prompt "Allow SQL fallback for validation" -Default $true
    $localCacheDbPath = Read-Host "Local cache DB path"; if ([string]::IsNullOrWhiteSpace($localCacheDbPath)) { $localCacheDbPath = "cache/freeadfsotp-node-cache.db" }
    $periodicSyncEnabled = Read-Bool -Prompt "Enable periodic cache sync" -Default $true

    $periodicSyncIntervalRaw = Read-Host "Periodic sync interval in seconds"; if ([string]::IsNullOrWhiteSpace($periodicSyncIntervalRaw)) { $periodicSyncIntervalRaw = "30" }
    $periodicSyncInterval = [int]$periodicSyncIntervalRaw

    $runAsLocalSystem = Read-Bool -Prompt "Run service as LocalSystem" -Default $true
    $serviceAccount = "LocalSystem"
    $serviceAccountPassword = ""
    if (-not $runAsLocalSystem) {
        $serviceAccount = Read-Host "Service account (domain\\user or .\\user)"
        $serviceAccountPassword = Read-Host "Service account password"
        if ([string]::IsNullOrWhiteSpace($serviceAccount)) { throw "ServiceAccount is required when not using LocalSystem." }
        if ([string]::IsNullOrWhiteSpace($serviceAccountPassword)) { throw "ServiceAccountPassword is required when not using LocalSystem." }
    }

    $config = @{
        ApiZipPath = $apiZipPath
        InstallRoot = $installRoot
        ServiceName = $serviceName
        DotnetPath = $dotnetPath
        ListenUrl = $listenUrl
        OtpSqlConnectionString = $otpSqlConnectionString
        MasterKeyBase64 = $masterKeyBase64
        AdminApiKey = $adminApiKey
        LocalCacheEnabled = $localCacheEnabled
        AllowSqlFallbackForValidation = $allowSqlFallback
        LocalCacheDatabasePath = $localCacheDbPath
        PeriodicSyncEnabled = $periodicSyncEnabled
        PeriodicSyncIntervalSeconds = $periodicSyncInterval
        ServiceAccount = $serviceAccount
        ServiceAccountPassword = $serviceAccountPassword
    }

    Write-ConfigFile -Path $configFullPath -Config $config
    Write-Host "Config saved: $configFullPath"
}

$config = Import-PowerShellDataFile -Path $configFullPath

$apiZipPath = Resolve-RepoPath $config.ApiZipPath
if (-not (Test-Path $apiZipPath)) {
    throw "API ZIP not found: $apiZipPath"
}

$installRoot = $config.InstallRoot
$serviceName = $config.ServiceName
$dotnetPath = $config.DotnetPath
$listenUrl = $config.ListenUrl
$appDir = $installRoot

if (-not (Test-Path $dotnetPath)) {
    throw "dotnet not found: $dotnetPath"
}

Invoke-IfNotDryRun -Description "Extract API package" -Action {
    if (Test-Path $appDir) {
        Remove-Item -Path $appDir -Recurse -Force
    }

    New-Item -Path $appDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $apiZipPath -DestinationPath $appDir -Force
}

$appSettingsPath = Join-Path $appDir "appsettings.json"
if (-not (Test-Path $appSettingsPath)) {
    throw "Missing appsettings.json in API package: $appSettingsPath"
}

Invoke-IfNotDryRun -Description "Update appsettings for local API node" -Action {
    Update-JsonFile -Path $appSettingsPath -Update {
        param($json)

    $connectionStrings = Get-OrAddJsonObjectProperty -Object $json -PropertyName "ConnectionStrings"
    $secretProtection = Get-OrAddJsonObjectProperty -Object $json -PropertyName "SecretProtection"
    $adminAuth = Get-OrAddJsonObjectProperty -Object $json -PropertyName "AdminAuth"
    $localCache = Get-OrAddJsonObjectProperty -Object $json -PropertyName "LocalCache"

        $connectionStrings.OtpSql = $config.OtpSqlConnectionString
        $secretProtection.MasterKey = $config.MasterKeyBase64
        $adminAuth.ApiKey = $config.AdminApiKey

        $localCache.Enabled = [bool]$config.LocalCacheEnabled
        $localCache.AllowSqlFallbackForValidation = [bool]$config.AllowSqlFallbackForValidation
        $localCache.DatabasePath = $config.LocalCacheDatabasePath
        $localCache.PeriodicSyncEnabled = [bool]$config.PeriodicSyncEnabled
        $localCache.PeriodicSyncIntervalSeconds = [int]$config.PeriodicSyncIntervalSeconds
    }
}

$apiDllPath = Join-Path $appDir "FreeAdfsOtp.Api.dll"
if (-not (Test-Path $apiDllPath)) {
    $apiDllCandidate = Get-ChildItem -Path $appDir -Filter "FreeAdfsOtp.Api.dll" -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($apiDllCandidate) {
        $apiDllPath = $apiDllCandidate.FullName
        Write-Host "API assembly discovered at: $apiDllPath"
    }
    else {
        throw "API assembly not found under: $appDir"
    }
}

Invoke-IfNotDryRun -Description "Clean existing service '$serviceName' if present" -Action {
    Remove-ServiceIfExists -Name $serviceName
}

$serviceCommandLine = ('"{0}" "{1}"' -f $dotnetPath, $apiDllPath)

Invoke-IfNotDryRun -Description "Create Windows service '$serviceName'" -Action {
    if ($config.ServiceAccount -eq "LocalSystem") {
        New-Service -Name $serviceName -BinaryPathName $serviceCommandLine -DisplayName $serviceName -StartupType Automatic | Out-Null
    }
    else {
        $securePassword = ConvertTo-SecureString -String $config.ServiceAccountPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($config.ServiceAccount, $securePassword)
        New-Service -Name $serviceName -BinaryPathName $serviceCommandLine -DisplayName $serviceName -StartupType Automatic -Credential $credential | Out-Null
    }

    $createdService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $createdService) {
        throw "Service '$serviceName' was not found after creation."
    }

    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" -Name "Environment" -PropertyType MultiString -Value @(
        "ASPNETCORE_ENVIRONMENT=Production",
        "ASPNETCORE_URLS=$listenUrl"
    ) -Force | Out-Null
}

Invoke-IfNotDryRun -Description "Start Windows service '$serviceName'" -Action {
    if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
        throw "Cannot start service '$serviceName' because it does not exist."
    }

    Start-Service -Name $serviceName
}

Write-Host "Local API service deployment completed."
Write-Host "Service: $serviceName"
Write-Host "App path: $appDir"
Write-Host "Listen URL: $listenUrl"
Write-Host "Adapter ApiBaseUrl should match this URL."
