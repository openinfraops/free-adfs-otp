param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\deploy\adfs\adfs-connector-update.config.psd1",

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
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
    ProviderName = '$(ConvertTo-Psd1SafeString $Config.ProviderName)'
    AdapterZipPath = '$(ConvertTo-Psd1SafeString $Config.AdapterZipPath)'
    ProviderConfigurationFilePath = '$(ConvertTo-Psd1SafeString $Config.ProviderConfigurationFilePath)'
    ForceReregister = `$$($Config.ForceReregister)
    RestartAdfsService = `$$($Config.RestartAdfsService)
}
"@

    $configDir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Set-Content -Path $Path -Value $content -Encoding UTF8
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

function Install-AssemblyInGac {
    param([string]$AssemblyPath)

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
        throw "Expected adapter type '$AdapterClassName' was not found in '$AssemblyPath'."
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

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Administrator)."
}

if (-not (Get-Command Register-AdfsAuthenticationProvider -ErrorAction SilentlyContinue)) {
    throw "AD FS PowerShell cmdlets not found on this machine. Run on an AD FS server."
}

$configFullPath = Resolve-RepoPath $ConfigPath
$configExists = Test-Path $configFullPath

if ($Interactive -or -not $configExists) {
    Write-Host "Interactive update setup for AD FS connector"

    $providerName = Read-Host "Provider name"
    if ([string]::IsNullOrWhiteSpace($providerName)) { $providerName = "Free-ADFS-OTP" }

    $adapterZipPath = Read-Host "Adapter ZIP path"
    if ([string]::IsNullOrWhiteSpace($adapterZipPath)) { throw "AdapterZipPath is required." }

    $providerConfigPath = Read-Host "Provider XML config path"
    if ([string]::IsNullOrWhiteSpace($providerConfigPath)) { throw "ProviderConfigurationFilePath is required." }

    $forceReregister = $true
    $restartAdfsService = $true

    $config = @{
        ProviderName = $providerName
        AdapterZipPath = $adapterZipPath
        ProviderConfigurationFilePath = $providerConfigPath
        ForceReregister = $forceReregister
        RestartAdfsService = $restartAdfsService
    }

    Write-ConfigFile -Path $configFullPath -Config $config
    Write-Host "Config saved: $configFullPath"
}

$config = Import-PowerShellDataFile -Path $configFullPath

$providerName = if ([string]::IsNullOrWhiteSpace($config.ProviderName)) { "Free-ADFS-OTP" } else { $config.ProviderName }
$adapterZipPath = Resolve-RepoPath $config.AdapterZipPath
$providerConfigurationFilePath = Resolve-RepoPath $config.ProviderConfigurationFilePath
$forceReregister = [bool]$config.ForceReregister
$restartAdfsService = [bool]$config.RestartAdfsService

if (-not (Test-Path $adapterZipPath)) {
    throw "Adapter ZIP not found: $adapterZipPath"
}

if (-not (Test-Path $providerConfigurationFilePath)) {
    throw "Provider configuration XML not found: $providerConfigurationFilePath"
}

$tempRoot = Join-Path $env:TEMP ("freeadfsotp-adapter-update-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Invoke-IfNotDryRun -Description "Extract adapter ZIP" -Action {
        Expand-Archive -Path $adapterZipPath -DestinationPath $tempRoot -Force
    }

    $adapterDll = Get-ChildItem -Path $tempRoot -Filter "FreeAdfsOtp.AdfsAdapter.dll" -Recurse | Select-Object -First 1
    if (-not $adapterDll) {
        throw "FreeAdfsOtp.AdfsAdapter.dll not found in ZIP: $adapterZipPath"
    }

    $typeName = Get-AdapterTypeName -AssemblyPath $adapterDll.FullName
    Write-Host "Auto-detected TypeName: $typeName"

    Invoke-IfNotDryRun -Description "Install adapter DLL in GAC" -Action {
        Install-AssemblyInGac -AssemblyPath $adapterDll.FullName
    }

    $existingProvider = Get-AdfsAuthenticationProvider | Where-Object { $_.Name -eq $providerName }
    $hadProviderInPolicy = $false
    if ($existingProvider) {
        $policy = Get-AdfsGlobalAuthenticationPolicy
        $providers = @($policy.AdditionalAuthenticationProvider)
        $hadProviderInPolicy = $providers -contains $providerName
    }

    if ($existingProvider -and $forceReregister) {
        Invoke-IfNotDryRun -Description "Unregister existing provider '$providerName'" -Action {
            $policy = Get-AdfsGlobalAuthenticationPolicy
            $providers = @($policy.AdditionalAuthenticationProvider)
            if ($hadProviderInPolicy) {
                $providers = $providers | Where-Object { $_ -ne $providerName }
                Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider $providers
            }

            Unregister-AdfsAuthenticationProvider -Name $providerName
        }
    }
    elseif ($existingProvider -and -not $forceReregister) {
        throw "Provider already exists: $providerName. Set ForceReregister=true in config to update it."
    }

    Invoke-IfNotDryRun -Description "Register provider '$providerName'" -Action {
        Register-AdfsAuthenticationProvider -TypeName $typeName -Name $providerName -ConfigurationFilePath $providerConfigurationFilePath

        if ($hadProviderInPolicy) {
            $policy = Get-AdfsGlobalAuthenticationPolicy
            $providers = @($policy.AdditionalAuthenticationProvider)
            if ($providers -notcontains $providerName) {
                $providers += $providerName
                Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider $providers
            }
        }
    }

    if ($restartAdfsService) {
        Invoke-IfNotDryRun -Description "Restart AD FS service" -Action {
            Restart-Service adfssrv -Force
        }
    }

    Invoke-IfNotDryRun -Description "Write ADFS connector update metadata to registry" -Action {
        Set-RegistryInstallMetadata -RegistryPath $AdfsConnectorRegistryPath -Values @{
            ProviderName = $providerName
            UpdateConfigPath = $configFullPath
            ProviderConfigPath = $providerConfigurationFilePath
        }
    }
}
finally {
    Invoke-IfNotDryRun -Description "Cleanup temporary directory" -Action {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force
        }
    }
}

Write-Host "ADFS connector update completed for provider: $providerName"