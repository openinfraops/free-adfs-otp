param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\adfs\adfs-node.config.psd1",

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPolicy,

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
    ProviderName = '$(Escape-Psd1String $Config.ProviderName)'
    TypeName = '$(Escape-Psd1String $Config.TypeName)'
    AdapterZipPath = '$(Escape-Psd1String $Config.AdapterZipPath)'
    GacutilPath = '$(Escape-Psd1String $Config.GacutilPath)'
    SqlConnectionString = '$(Escape-Psd1String $Config.SqlConnectionString)'
    SecretMasterKeyBase64 = '$(Escape-Psd1String $Config.SecretMasterKeyBase64)'
    EnrollmentPortalBaseUrl = '$(Escape-Psd1String $Config.EnrollmentPortalBaseUrl)'
    RequireExternalOnly = `$$($Config.RequireExternalOnly)
    ApplyGlobalRule = `$$($Config.ApplyGlobalRule)
    ForceReregister = `$$($Config.ForceReregister)
    RestartAdfsService = `$$($Config.RestartAdfsService)
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

function Build-ProviderConfigXml {
    param(
                [string]$SqlConnectionString,
                [string]$SecretMasterKeyBase64,
        [string]$EnrollmentPortalBaseUrl,
        [string]$DestinationPath
    )

    $xml = @"
<Config>
    <Mode>SqlDirect</Mode>
    <SqlConnectionString>$SqlConnectionString</SqlConnectionString>
    <SecretMasterKeyBase64>$SecretMasterKeyBase64</SecretMasterKeyBase64>
  <EnrollmentPortalBaseUrl>$EnrollmentPortalBaseUrl</EnrollmentPortalBaseUrl>
</Config>
"@

    Set-Content -Path $DestinationPath -Value $xml -Encoding UTF8
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

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Administrator)."
}

if (-not (Get-Command Register-AdfsAuthenticationProvider -ErrorAction SilentlyContinue)) {
    throw "AD FS PowerShell cmdlets not found on this machine. Run on an AD FS server."
}

$configFullPath = Resolve-RepoPath $ConfigPath
$configExists = Test-Path $configFullPath

if ($Interactive -or -not $configExists) {
    Write-Host "Interactive setup for AD FS OTP node"

    $providerName = Read-Host "Provider name"; if ([string]::IsNullOrWhiteSpace($providerName)) { $providerName = "freeADFSOtp" }
    $typeName = Read-Host "Provider TypeName (strong type incl. public key token)"
    if ([string]::IsNullOrWhiteSpace($typeName)) {
        throw "TypeName is required."
    }

    $adapterZipPath = Read-Host "Adapter ZIP path (e.g. C:\packages\freeADFSOtp-v1.0.0-adfs-node-package.zip)"
    $gacutilPath = Read-Host "gacutil.exe path"; if ([string]::IsNullOrWhiteSpace($gacutilPath)) { $gacutilPath = "C:\Tools\gacutil.exe" }
    $sqlConnectionString = Read-Host "SQL connection string for OTP validation"
    if ([string]::IsNullOrWhiteSpace($sqlConnectionString)) { throw "SqlConnectionString is required." }
    $secretMasterKeyBase64 = Read-Host "Secret master key base64 (same key as API)"
    if ([string]::IsNullOrWhiteSpace($secretMasterKeyBase64)) { throw "SecretMasterKeyBase64 is required." }
    $enrollmentPortalBaseUrl = Read-Host "Enrollment portal URL"; if ([string]::IsNullOrWhiteSpace($enrollmentPortalBaseUrl)) { throw "EnrollmentPortalBaseUrl is required." }

    $requireExternalOnly = Read-Bool -Prompt "Apply MFA rule only for external users" -Default $true
    $applyGlobalRule = Read-Bool -Prompt "Configure AD FS global additional auth rule" -Default $true
    $forceReregister = Read-Bool -Prompt "Force re-register provider if already present" -Default $true
    $restartAdfsService = Read-Bool -Prompt "Restart AD FS service after registration" -Default $true

    $config = @{
        ProviderName = $providerName
        TypeName = $typeName
        AdapterZipPath = $adapterZipPath
        GacutilPath = $gacutilPath
        SqlConnectionString = $sqlConnectionString
        SecretMasterKeyBase64 = $secretMasterKeyBase64
        EnrollmentPortalBaseUrl = $enrollmentPortalBaseUrl
        RequireExternalOnly = $requireExternalOnly
        ApplyGlobalRule = $applyGlobalRule
        ForceReregister = $forceReregister
        RestartAdfsService = $restartAdfsService
    }

    Write-ConfigFile -Path $configFullPath -Config $config
    Write-Host "Config saved: $configFullPath"
}

$config = Import-PowerShellDataFile -Path $configFullPath

$providerName = $config.ProviderName
$typeName = $config.TypeName
$adapterZipPath = Resolve-RepoPath $config.AdapterZipPath
$gacutilPath = Resolve-RepoPath $config.GacutilPath
$sqlConnectionString = $config.SqlConnectionString
$secretMasterKeyBase64 = $config.SecretMasterKeyBase64
$enrollmentPortalBaseUrl = $config.EnrollmentPortalBaseUrl
$requireExternalOnly = [bool]$config.RequireExternalOnly
$applyGlobalRule = if ($SkipPolicy) { $false } else { [bool]$config.ApplyGlobalRule }
$forceReregister = [bool]$config.ForceReregister
$restartAdfsService = [bool]$config.RestartAdfsService

if (-not (Test-Path $adapterZipPath)) {
    throw "Adapter ZIP not found: $adapterZipPath"
}

if (-not (Test-Path $gacutilPath)) {
    throw "gacutil.exe not found: $gacutilPath"
}

$tempRoot = Join-Path $env:TEMP ("freeadfsotp-adfs-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Invoke-IfNotDryRun -Description "Extract adapter ZIP to temp directory" -Action {
    Expand-Archive -Path $adapterZipPath -DestinationPath $tempRoot -Force
}

$adapterDll = Get-ChildItem -Path $tempRoot -Filter "FreeAdfsOtp.AdfsAdapter.dll" -Recurse | Select-Object -First 1
if (-not $adapterDll) {
    throw "FreeAdfsOtp.AdfsAdapter.dll not found in ZIP: $adapterZipPath"
}

$providerConfigPath = Join-Path (Split-Path -Parent $configFullPath) "provider-config.generated.xml"
Build-ProviderConfigXml -SqlConnectionString $sqlConnectionString -SecretMasterKeyBase64 $secretMasterKeyBase64 -EnrollmentPortalBaseUrl $enrollmentPortalBaseUrl -DestinationPath $providerConfigPath
Write-Host "Provider XML generated: $providerConfigPath"

Invoke-IfNotDryRun -Description "Install adapter DLL into GAC" -Action {
    & $gacutilPath /if $adapterDll.FullName
}

$existingProvider = Get-AdfsAuthenticationProvider | Where-Object { $_.Name -eq $providerName }
if ($existingProvider -and $forceReregister) {
    Invoke-IfNotDryRun -Description "Unregister existing AD FS provider" -Action {
        $policy = Get-AdfsGlobalAuthenticationPolicy
        $providers = @($policy.AdditionalAuthenticationProvider) | Where-Object { $_ -ne $providerName }
        Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider $providers
        Unregister-AdfsAuthenticationProvider -Name $providerName
    }
}
elseif ($existingProvider -and -not $forceReregister) {
    throw "Provider already exists: $providerName. Enable ForceReregister in config or remove provider first."
}

Invoke-IfNotDryRun -Description "Register AD FS provider" -Action {
    Register-AdfsAuthenticationProvider -TypeName $typeName -Name $providerName -ConfigurationFilePath $providerConfigPath
}

if ($applyGlobalRule) {
    Invoke-IfNotDryRun -Description "Configure AD FS MFA policy" -Action {
        $policy = Get-AdfsGlobalAuthenticationPolicy
        $providers = @($policy.AdditionalAuthenticationProvider)
        if ($providers -notcontains $providerName) {
            $providers += $providerName
            Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider $providers
        }

        if ($requireExternalOnly) {
            $rule = 'c:[type == "http://schemas.microsoft.com/ws/2012/01/insidecorporatenetwork", value == "false"] => issue(type = "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod", value = "http://schemas.microsoft.com/claims/multipleauthn" );'
        }
        else {
            $rule = '=> issue(type = "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod", value = "http://schemas.microsoft.com/claims/multipleauthn" );'
        }

        Set-AdfsAdditionalAuthenticationRule -AdditionalAuthenticationRules $rule
    }
}

if ($restartAdfsService) {
    Invoke-IfNotDryRun -Description "Restart AD FS service" -Action {
        Restart-Service adfssrv -Force
    }
}

Write-Host "Deployment completed for provider: $providerName"
Write-Host "Reusable node config: $configFullPath"
Write-Host "Reusable provider XML: $providerConfigPath"
