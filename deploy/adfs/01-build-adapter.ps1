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
    [string]$OutputPath = ".\artifacts\adfs-adapter"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DotnetPath)) {
    throw "dotnet not found at $DotnetPath"
}

if (-not (Test-Path $ProjectPath)) {
    throw "Project file not found: $ProjectPath"
}

$projectFullPath = Resolve-Path $ProjectPath
$outputFullPath = Resolve-Path "." | ForEach-Object { Join-Path $_ $OutputPath }
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null

$msbuildProps = @(
    "/p:DefineConstants=ADFS_SERVER",
    "/p:CopyLocalLockFileAssemblies=true"
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

Write-Host "Adapter build output: $outputFullPath"
