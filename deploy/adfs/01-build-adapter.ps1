param(
    [Parameter(Mandatory = $false)]
    [string]$Configuration = "Release",

    [Parameter(Mandatory = $false)]
    [string]$Framework = "net47",

    [Parameter(Mandatory = $false)]
    [string]$DotnetPath = "C:\Program Files\dotnet\dotnet.exe",

    [Parameter(Mandatory = $false)]
    [string]$ProjectPath = ".\src\FreeAdfsOtp.AdfsAdapter\FreeAdfsOtp.AdfsAdapter.csproj",

    [Parameter(Mandatory = $false)]
    [string]$AdfsAssemblyPath = "",

    [Parameter(Mandatory = $false)]
    [string]$AdapterVersion = "",

    [Parameter(Mandatory = $false)]
    [string]$AdapterVersionFile = ".\build\adfs-adapter.version",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\artifacts\adfs-adapter"
)

$ErrorActionPreference = "Stop"

function Resolve-AdapterVersion {
    param(
        [string]$ExplicitVersion,
        [string]$VersionFilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        $version = $ExplicitVersion.Trim()
    }
    else {
        if (-not (Test-Path $VersionFilePath)) {
            throw "Adapter version file not found: $VersionFilePath"
        }

        $version = (Get-Content -Path $VersionFilePath -Raw).Trim()
    }

    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid adapter version '$version'. Expected format: Major.Minor.Patch (example: 1.0.0)."
    }

    return $version
}

if (-not (Test-Path $DotnetPath)) {
    throw "dotnet not found at $DotnetPath"
}

if (-not (Test-Path $ProjectPath)) {
    throw "Project file not found: $ProjectPath"
}

$projectFullPath = Resolve-Path $ProjectPath
$outputFullPath = Resolve-Path "." | ForEach-Object { Join-Path $_ $OutputPath }
$versionFileFullPath = Resolve-Path "." | ForEach-Object { Join-Path $_ $AdapterVersionFile }
$resolvedAdapterVersion = Resolve-AdapterVersion -ExplicitVersion $AdapterVersion -VersionFilePath $versionFileFullPath
$assemblyVersion = "$resolvedAdapterVersion.0"
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null

$msbuildProps = @(
    "/p:DefineConstants=ADFS_SERVER",
    "/p:CopyLocalLockFileAssemblies=true",
    "/p:Version=$resolvedAdapterVersion",
    "/p:InformationalVersion=$resolvedAdapterVersion",
    "/p:AssemblyVersion=$assemblyVersion",
    "/p:FileVersion=$assemblyVersion"
)

if (-not [string]::IsNullOrWhiteSpace($AdfsAssemblyPath)) {
    if (-not (Test-Path $AdfsAssemblyPath)) {
        throw "Microsoft.IdentityServer.Web.dll path not found: $AdfsAssemblyPath"
    }

    $adfsDllFullPath = (Resolve-Path $AdfsAssemblyPath).Path
    $msbuildProps += "/p:AdfsWebDll=$adfsDllFullPath"
}

Write-Host "Restoring adapter project..."
& $DotnetPath restore $projectFullPath

Write-Host "Building adapter with ADFS_SERVER constant..."
& $DotnetPath build $projectFullPath -c $Configuration -f $Framework -o $outputFullPath @msbuildProps

Write-Host "Adapter version applied: $resolvedAdapterVersion"
Write-Host "Adapter build output: $outputFullPath"
