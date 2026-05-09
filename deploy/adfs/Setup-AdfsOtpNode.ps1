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
$FixedProviderName = "Free-ADFS-OTP"

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

function Build-SqlConnectionString {
    param(
        [string]$SqlServer,
        [string]$SqlDatabase,
        [bool]$UseIntegratedSecurity,
        [string]$SqlUser,
        [string]$SqlPassword
    )

    if ([string]::IsNullOrWhiteSpace($SqlServer)) {
        throw "SqlServer is required."
    }

    if ([string]::IsNullOrWhiteSpace($SqlDatabase)) {
        $SqlDatabase = "FreeAdfsOtp"
    }

    if ($UseIntegratedSecurity) {
        return "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=true;TrustServerCertificate=true;"
    }

    if ([string]::IsNullOrWhiteSpace($SqlUser)) {
        throw "SqlUser is required when integrated security is disabled."
    }

    if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
        throw "SqlPassword is required when integrated security is disabled."
    }

    return "Server=$SqlServer;Database=$SqlDatabase;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=true;"
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

function Install-AssemblyInGac {
    param(
        [string]$AssemblyPath,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] Publish.GacInstall($AssemblyPath)"
        return
    }

    Add-Type -AssemblyName System.EnterpriseServices
    $publish = New-Object System.EnterpriseServices.Internal.Publish
    $publish.GacInstall($AssemblyPath)
}

function Get-AdapterTypeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssemblyPath,

        [Parameter(Mandatory = $false)]
        [string]$AdapterClassName = "FreeAdfsOtp.AdfsAdapter.AdapterRuntime.FreeAdfsOtpAuthenticationAdapter"
    )

    $assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($AssemblyPath)
    $pktBytes = $assemblyName.GetPublicKeyToken()
    $pkt = if ($pktBytes -and $pktBytes.Length -gt 0) {
        ([System.BitConverter]::ToString($pktBytes)).Replace('-', '').ToLowerInvariant()
    }
    else {
        "null"
    }

    $culture = if ([string]::IsNullOrWhiteSpace($assemblyName.CultureName)) {
        "neutral"
    }
    else {
        $assemblyName.CultureName
    }

    return "$AdapterClassName, $($assemblyName.Name), Version=$($assemblyName.Version), Culture=$culture, PublicKeyToken=$pkt, processorArchitecture=MSIL"
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

    $providerName = $FixedProviderName
    Write-Host "Provider name is fixed to: $providerName"

    $adapterZipPath = Read-Host "Adapter ZIP path (e.g. C:\packages\freeADFSOtp-v1.0.0-adfs-node-package.zip)"

    $sqlServer = Read-Host "SQL server name (host\\instance or host,port)"
    $sqlDatabase = Read-Host "SQL database name"; if ([string]::IsNullOrWhiteSpace($sqlDatabase)) { $sqlDatabase = "FreeAdfsOtp" }
    $useIntegratedSecurity = Read-Bool -Prompt "Use integrated security for SQL" -Default $true

    $sqlUser = ""
    $sqlPassword = ""
    if (-not $useIntegratedSecurity) {
        $sqlUser = Read-Host "SQL user"
        $sqlPassword = Read-Host "SQL password (stored in plain text in config)"
    }

    $sqlConnectionString = Build-SqlConnectionString -SqlServer $sqlServer -SqlDatabase $sqlDatabase -UseIntegratedSecurity $useIntegratedSecurity -SqlUser $sqlUser -SqlPassword $sqlPassword

    $secretMasterKeyBase64 = Read-Host "Secret master key base64 (same key as API)"
    if ([string]::IsNullOrWhiteSpace($secretMasterKeyBase64)) { throw "SecretMasterKeyBase64 is required." }
    $enrollmentPortalBaseUrl = Read-Host "Enrollment portal URL"; if ([string]::IsNullOrWhiteSpace($enrollmentPortalBaseUrl)) { throw "EnrollmentPortalBaseUrl is required." }

    $requireExternalOnly = Read-Bool -Prompt "Apply MFA rule only for external users" -Default $true
    $applyGlobalRule = Read-Bool -Prompt "Configure AD FS global additional auth rule" -Default $true
    $forceReregister = Read-Bool -Prompt "Force re-register provider if already present" -Default $true
    $restartAdfsService = Read-Bool -Prompt "Restart AD FS service after registration" -Default $true

    $config = @{
        ProviderName = $providerName
        TypeName = ""
        AdapterZipPath = $adapterZipPath
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

if ($config.ContainsKey("ProviderName") -and -not [string]::IsNullOrWhiteSpace($config.ProviderName) -and $config.ProviderName -ne $FixedProviderName) {
    Write-Warning "ProviderName '$($config.ProviderName)' in config is ignored. Using fixed name '$FixedProviderName'."
}

$providerName = $FixedProviderName
$adapterZipPath = Resolve-RepoPath $config.AdapterZipPath
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

$tempRoot = Join-Path $env:TEMP ("freeadfsotp-adfs-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Invoke-IfNotDryRun -Description "Extract adapter ZIP to temp directory" -Action {
    Expand-Archive -Path $adapterZipPath -DestinationPath $tempRoot -Force
}

$adapterDll = Get-ChildItem -Path $tempRoot -Filter "FreeAdfsOtp.AdfsAdapter.dll" -Recurse | Select-Object -First 1
if (-not $adapterDll) {
    throw "FreeAdfsOtp.AdfsAdapter.dll not found in ZIP: $adapterZipPath"
}

$typeName = Get-AdapterTypeName -AssemblyPath $adapterDll.FullName
Write-Host "Auto-detected TypeName: $typeName"

$providerConfigPath = Join-Path (Split-Path -Parent $configFullPath) "provider-config.generated.xml"
Build-ProviderConfigXml -SqlConnectionString $sqlConnectionString -SecretMasterKeyBase64 $secretMasterKeyBase64 -EnrollmentPortalBaseUrl $enrollmentPortalBaseUrl -DestinationPath $providerConfigPath
Write-Host "Provider XML generated: $providerConfigPath"

Invoke-IfNotDryRun -Description "Install adapter DLL into GAC" -Action {
    Install-AssemblyInGac -AssemblyPath $adapterDll.FullName
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
