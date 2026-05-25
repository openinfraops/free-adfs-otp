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
$RegistryRootPath = "HKLM:\SOFTWARE\FreeAdfsOtp"
$AdfsConnectorRegistryPath = Join-Path $RegistryRootPath "AdfsConnector"

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
    Mode = '$(Escape-Psd1String $Config.Mode)'
    AdapterZipPath = '$(Escape-Psd1String $Config.AdapterZipPath)'
    SqlConnectionString = '$(Escape-Psd1String $Config.SqlConnectionString)'
    SecretMasterKeyBase64 = '$(Escape-Psd1String $Config.SecretMasterKeyBase64)'
    ApiBaseUrl = '$(Escape-Psd1String $Config.ApiBaseUrl)'
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

function Read-Mode {
    param([string]$Default = "SqlDirect")

    $raw = Read-Host "Backend mode [SqlDirect/Api] (default: $Default)"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    switch ($normalized) {
        "sqldirect" { return "SqlDirect" }
        "sql" { return "SqlDirect" }
        "api" { return "Api" }
        default { throw "Invalid mode '$raw'. Allowed values: SqlDirect, Api." }
    }
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
        [string]$Mode,
        [string]$SqlConnectionString,
        [string]$SecretMasterKeyBase64,
        [string]$ApiBaseUrl,
        [string]$EnrollmentPortalBaseUrl,
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "Mode is required."
    }

    if ($Mode -eq "SqlDirect") {
        if ([string]::IsNullOrWhiteSpace($SqlConnectionString)) {
            throw "SqlConnectionString is required for SqlDirect mode."
        }

        if ([string]::IsNullOrWhiteSpace($SecretMasterKeyBase64)) {
            throw "SecretMasterKeyBase64 is required for SqlDirect mode."
        }

        $xml = @"
<Config>
    <Mode>$Mode</Mode>
    <SqlConnectionString>$SqlConnectionString</SqlConnectionString>
    <SecretMasterKeyBase64>$SecretMasterKeyBase64</SecretMasterKeyBase64>
    <EnrollmentPortalBaseUrl>$EnrollmentPortalBaseUrl</EnrollmentPortalBaseUrl>
</Config>
"@
    }
    elseif ($Mode -eq "Api") {
        if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
            throw "ApiBaseUrl is required for Api mode."
        }

        $xml = @"
<Config>
    <Mode>$Mode</Mode>
    <ApiBaseUrl>$ApiBaseUrl</ApiBaseUrl>
    <EnrollmentPortalBaseUrl>$EnrollmentPortalBaseUrl</EnrollmentPortalBaseUrl>
</Config>
"@
    }
    else {
        throw "Unsupported mode '$Mode'. Allowed values: SqlDirect, Api."
    }

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

    $assemblyDirectory = Split-Path -Parent $AssemblyPath
    $adfsDllCandidates = @(
        (Join-Path $assemblyDirectory "Microsoft.IdentityServer.Web.dll"),
        (Join-Path $env:windir "ADFS\Microsoft.IdentityServer.Web.dll")
    )

    foreach ($candidate in $adfsDllCandidates) {
        if (Test-Path $candidate) {
            try {
                [void][System.Reflection.Assembly]::LoadFrom($candidate)
                break
            }
            catch {
                Write-Warning "Unable to preload dependency '$candidate': $($_.Exception.Message)"
            }
        }
    }

    $loadedAssembly = [System.Reflection.Assembly]::LoadFrom($AssemblyPath)
    $adapterType = $loadedAssembly.GetType($AdapterClassName, $false, $false)
    if (-not $adapterType) {
        $discoveredTypes = @()
        $loaderExceptionMessages = @()

        try {
            $discoveredTypes = $loadedAssembly.GetTypes() |
                Where-Object { $_.IsClass -and $_.FullName -like "*AuthenticationAdapter*" } |
                ForEach-Object { $_.FullName }
        }
        catch [System.Reflection.ReflectionTypeLoadException] {
            $discoveredTypes = $_.Exception.Types |
                Where-Object { $null -ne $_ -and $_.IsClass -and $_.FullName -like "*AuthenticationAdapter*" } |
                ForEach-Object { $_.FullName }

            $loaderExceptionMessages = $_.Exception.LoaderExceptions |
                Where-Object { $null -ne $_ } |
                ForEach-Object { $_.Message }
        }

        $discoveredText = if ($discoveredTypes -and $discoveredTypes.Count -gt 0) {
            ($discoveredTypes -join ", ")
        }
        else {
            "none"
        }

    $loaderExceptionText = if ($loaderExceptionMessages -and $loaderExceptionMessages.Count -gt 0) {
@"

Loader exceptions:
- $($loaderExceptionMessages -join "`n- ")
"@
    }
    else {
        ""
    }

        throw @"
Expected adapter type '$AdapterClassName' was not found in '$AssemblyPath'.
Discovered adapter-like types: $discoveredText
$loaderExceptionText

This usually means the adapter was built without the ADFS runtime symbol.
Rebuild using one of the following:
- .\deploy\adfs\01-build-adapter.ps1 (already sets /p:DefineConstants=ADFS_SERVER)
- .\deploy\package-artifacts.ps1 -BuildAdfsRuntime
"@
    }

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

function Set-RegistryInstallMetadata {
    param(
        [string]$RegistryPath,
        [hashtable]$Values
    )

    New-Item -Path $RegistryPath -Force | Out-Null
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        New-ItemProperty -Path $RegistryPath -Name $key -Value $value -PropertyType String -Force | Out-Null
    }
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

    $mode = Read-Mode -Default "SqlDirect"

    $adapterZipPath = Read-Host "Adapter ZIP path (e.g. C:\packages\freeADFSOtp-v1.0.0-adfs-node-package.zip)"

    $sqlConnectionString = ""
    $secretMasterKeyBase64 = ""
    $apiBaseUrl = ""
    if ($mode -eq "SqlDirect") {
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
        if ([string]::IsNullOrWhiteSpace($secretMasterKeyBase64)) { throw "SecretMasterKeyBase64 is required for SqlDirect mode." }
    }
    else {
        $apiBaseUrl = Read-Host "API base URL (e.g. https://localhost:7043 or http://127.0.0.1:5180)"
        if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) { throw "ApiBaseUrl is required for Api mode." }
    }

    $enrollmentPortalBaseUrl = Read-Host "Enrollment portal URL"; if ([string]::IsNullOrWhiteSpace($enrollmentPortalBaseUrl)) { throw "EnrollmentPortalBaseUrl is required." }

    $requireExternalOnly = Read-Bool -Prompt "Apply MFA rule only for external users" -Default $true
    $applyGlobalRule = Read-Bool -Prompt "Configure AD FS global additional auth rule" -Default $true
    $forceReregister = Read-Bool -Prompt "Force re-register provider if already present" -Default $true
    $restartAdfsService = Read-Bool -Prompt "Restart AD FS service after registration" -Default $true

    $config = @{
        ProviderName = $providerName
        TypeName = ""
        Mode = $mode
        AdapterZipPath = $adapterZipPath
        SqlConnectionString = $sqlConnectionString
        SecretMasterKeyBase64 = $secretMasterKeyBase64
        ApiBaseUrl = $apiBaseUrl
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
$mode = if ($config.ContainsKey("Mode") -and -not [string]::IsNullOrWhiteSpace($config.Mode)) { [string]$config.Mode } else { "SqlDirect" }
$adapterZipPath = Resolve-RepoPath $config.AdapterZipPath
$sqlConnectionString = $config.SqlConnectionString
$secretMasterKeyBase64 = $config.SecretMasterKeyBase64
$apiBaseUrl = $config.ApiBaseUrl
$enrollmentPortalBaseUrl = $config.EnrollmentPortalBaseUrl
$requireExternalOnly = [bool]$config.RequireExternalOnly
$applyGlobalRule = if ($SkipPolicy) { $false } else { [bool]$config.ApplyGlobalRule }
$forceReregister = [bool]$config.ForceReregister
$restartAdfsService = [bool]$config.RestartAdfsService

if (-not (Test-Path $adapterZipPath)) {
    throw "Adapter ZIP not found: $adapterZipPath"
}

if ($mode -eq "SqlDirect") {
    if ([string]::IsNullOrWhiteSpace($sqlConnectionString)) {
        throw "SqlConnectionString is required for SqlDirect mode."
    }

    if ([string]::IsNullOrWhiteSpace($secretMasterKeyBase64)) {
        throw "SecretMasterKeyBase64 is required for SqlDirect mode."
    }
}
elseif ($mode -eq "Api") {
    if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
        throw "ApiBaseUrl is required for Api mode."
    }
}
else {
    throw "Unsupported mode '$mode'. Allowed values: SqlDirect, Api."
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
Build-ProviderConfigXml -Mode $mode -SqlConnectionString $sqlConnectionString -SecretMasterKeyBase64 $secretMasterKeyBase64 -ApiBaseUrl $apiBaseUrl -EnrollmentPortalBaseUrl $enrollmentPortalBaseUrl -DestinationPath $providerConfigPath
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

Invoke-IfNotDryRun -Description "Write ADFS connector install metadata to registry" -Action {
    Set-RegistryInstallMetadata -RegistryPath $AdfsConnectorRegistryPath -Values @{
        ProviderName = $providerName
        Mode = $mode
        ApiBaseUrl = $apiBaseUrl
        NodeConfigPath = $configFullPath
        ProviderConfigPath = $providerConfigPath
    }
}

Write-Host "Deployment completed for provider: $providerName"
Write-Host "Reusable node config: $configFullPath"
Write-Host "Reusable provider XML: $providerConfigPath"
