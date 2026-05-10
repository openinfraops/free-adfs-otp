param(
    [Parameter(Mandatory = $false)]
    [string]$Configuration = "Release",

    [Parameter(Mandatory = $false)]
    [string]$DotnetPath = "dotnet",

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = ".\artifacts\packages",

    [Parameter(Mandatory = $false)]
    [string]$PackagePrefix = "freeADFSOtp",

    [Parameter(Mandatory = $false)]
    [switch]$SignAdapter = $false,

    [Parameter(Mandatory = $false)]
    [string]$AdapterKeyFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$BuildAdfsRuntime = $true,

    [Parameter(Mandatory = $false)]
    [string]$AdfsWebDll = "",

    [Parameter(Mandatory = $false)]
    [switch]$CreateBundle = $true
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$RelativePath)

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    return Join-Path $repoRoot $RelativePath
}

function Reset-Directory {
    param([string]$Path)

    if (Test-Path $Path) {
        Remove-Item -Recurse -Force $Path
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function New-ZipFromDirectory {
    param(
        [string]$SourceDirectory,
        [string]$ZipFilePath
    )

    if (Test-Path $ZipFilePath) {
        Remove-Item -Force $ZipFilePath
    }

    Compress-Archive -Path (Join-Path $SourceDirectory '*') -DestinationPath $ZipFilePath -CompressionLevel Optimal
}

$apiProject = Resolve-RepoPath "src\FreeAdfsOtp.Api\FreeAdfsOtp.Api.csproj"
$enrollmentProject = Resolve-RepoPath "src\FreeAdfsOtp.EnrollmentPortal\FreeAdfsOtp.EnrollmentPortal.csproj"
$adminProject = Resolve-RepoPath "src\FreeAdfsOtp.AdminPortal\FreeAdfsOtp.AdminPortal.csproj"
$adapterProject = Resolve-RepoPath "src\FreeAdfsOtp.AdfsAdapter\FreeAdfsOtp.AdfsAdapter.csproj"
$deployAdfsPath = Resolve-RepoPath "deploy\adfs"
$deployWebPath = Resolve-RepoPath "deploy\web"
$docsPath = Resolve-RepoPath "docs"
$sqlPath = Resolve-RepoPath "sql"

$outputRootFull = Resolve-RepoPath $OutputRoot
$stagingRoot = Join-Path $outputRootFull "staging"
$zipRoot = Join-Path $outputRootFull "zip"
$bundleRoot = Join-Path $stagingRoot "bundle-complete"

Reset-Directory -Path $stagingRoot
Reset-Directory -Path $zipRoot

Write-Host "Publishing API..."
& $DotnetPath publish $apiProject -c $Configuration -o (Join-Path $stagingRoot "api")

Write-Host "Publishing enrollment portal..."
& $DotnetPath publish $enrollmentProject -c $Configuration -o (Join-Path $stagingRoot "enrollment-portal")

Write-Host "Publishing admin portal..."
& $DotnetPath publish $adminProject -c $Configuration -o (Join-Path $stagingRoot "admin-portal")

Write-Host "Building AD FS adapter..."
$adapterBuildArgs = @(
    "build",
    $adapterProject,
    "-c", $Configuration,
    "--no-restore"
)

if ($SignAdapter -and -not [string]::IsNullOrWhiteSpace($AdapterKeyFile)) {
    $adapterBuildArgs += "-p:SignAdapterAssembly=true"
    $adapterBuildArgs += "-p:AdapterKeyFile=$AdapterKeyFile"
}

if ($BuildAdfsRuntime) {
    $adapterBuildArgs += "-p:DefineConstants=ADFS_SERVER"

    if (-not [string]::IsNullOrWhiteSpace($AdfsWebDll)) {
        $adapterBuildArgs += "-p:AdfsWebDll=$AdfsWebDll"
    }
}

& $DotnetPath @adapterBuildArgs

$adapterOutput = Resolve-RepoPath "src\FreeAdfsOtp.AdfsAdapter\bin\$Configuration\net45"
$adapterStaging = Join-Path $stagingRoot "adfs-adapter"
New-Item -ItemType Directory -Path $adapterStaging -Force | Out-Null
Copy-Item -Recurse -Force (Join-Path $adapterOutput '*') $adapterStaging
New-Item -ItemType Directory -Path (Join-Path $adapterStaging "deploy-adfs") -Force | Out-Null
Copy-Item -Recurse -Force (Join-Path $deployAdfsPath '*') (Join-Path $adapterStaging "deploy-adfs")
Copy-Item -Force (Join-Path $docsPath 'adfs-integration.md') $adapterStaging

$adfsPackageStaging = Join-Path $stagingRoot "adfs-node-package"
Reset-Directory -Path $adfsPackageStaging
New-Item -ItemType Directory -Path (Join-Path $adfsPackageStaging "adapter") -Force | Out-Null
Copy-Item -Recurse -Force (Join-Path $adapterStaging '*') (Join-Path $adfsPackageStaging "adapter")
New-Item -ItemType Directory -Path (Join-Path $adfsPackageStaging "deploy\adfs") -Force | Out-Null
Copy-Item -Recurse -Force (Join-Path $deployAdfsPath '*') (Join-Path $adfsPackageStaging "deploy\adfs")
Copy-Item -Recurse -Force $sqlPath (Join-Path $adfsPackageStaging "sql")
Copy-Item -Force (Join-Path $docsPath 'adfs-integration.md') $adfsPackageStaging

$adminPackageStaging = Join-Path $stagingRoot "admin-server-package"
Reset-Directory -Path $adminPackageStaging
New-Item -ItemType Directory -Path (Join-Path $adminPackageStaging "apps") -Force | Out-Null
New-ZipFromDirectory -SourceDirectory (Join-Path $stagingRoot "api") -ZipFilePath (Join-Path $adminPackageStaging "apps\api.zip")
New-ZipFromDirectory -SourceDirectory (Join-Path $stagingRoot "enrollment-portal") -ZipFilePath (Join-Path $adminPackageStaging "apps\enrollment-portal.zip")
New-ZipFromDirectory -SourceDirectory (Join-Path $stagingRoot "admin-portal") -ZipFilePath (Join-Path $adminPackageStaging "apps\admin-portal.zip")
New-Item -ItemType Directory -Path (Join-Path $adminPackageStaging "deploy\web") -Force | Out-Null
Copy-Item -Force (Join-Path $deployWebPath 'Setup-WebOtpNode.ps1') (Join-Path $adminPackageStaging "deploy\web\Setup-WebOtpNode.ps1")
Copy-Item -Force (Join-Path $deployWebPath 'Update-EnrollmentPortal.ps1') (Join-Path $adminPackageStaging "deploy\web\Update-EnrollmentPortal.ps1")
Copy-Item -Recurse -Force $sqlPath (Join-Path $adminPackageStaging "sql")
Copy-Item -Force (Join-Path $docsPath 'runbook-local.md') $adminPackageStaging
Copy-Item -Force (Join-Path $docsPath 'architecture.md') $adminPackageStaging

Write-Host "Creating ZIP packages..."
New-ZipFromDirectory -SourceDirectory (Join-Path $stagingRoot "api") -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-api.zip")
New-ZipFromDirectory -SourceDirectory (Join-Path $stagingRoot "enrollment-portal") -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-enrollment-portal.zip")
New-ZipFromDirectory -SourceDirectory (Join-Path $stagingRoot "admin-portal") -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-admin-portal.zip")
New-ZipFromDirectory -SourceDirectory $adapterStaging -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-adfs-adapter.zip")
New-ZipFromDirectory -SourceDirectory $adfsPackageStaging -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-adfs-node-package.zip")
New-ZipFromDirectory -SourceDirectory $adminPackageStaging -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-admin-server-package.zip")

if ($CreateBundle) {
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    Copy-Item -Recurse -Force (Join-Path $stagingRoot "api") (Join-Path $bundleRoot "api")
    Copy-Item -Recurse -Force (Join-Path $stagingRoot "enrollment-portal") (Join-Path $bundleRoot "enrollment-portal")
    Copy-Item -Recurse -Force (Join-Path $stagingRoot "admin-portal") (Join-Path $bundleRoot "admin-portal")
    Copy-Item -Recurse -Force $adapterStaging (Join-Path $bundleRoot "adfs-adapter")
    Copy-Item -Recurse -Force $adfsPackageStaging (Join-Path $bundleRoot "adfs-node-package")
    Copy-Item -Recurse -Force $adminPackageStaging (Join-Path $bundleRoot "admin-server-package")
    Copy-Item -Recurse -Force $deployAdfsPath (Join-Path $bundleRoot "deploy-adfs")
    Copy-Item -Recurse -Force $deployWebPath (Join-Path $bundleRoot "deploy-web")
    Copy-Item -Recurse -Force $docsPath (Join-Path $bundleRoot "docs")
    Copy-Item -Recurse -Force $sqlPath (Join-Path $bundleRoot "sql")
    Copy-Item -Force (Resolve-RepoPath "README.md") $bundleRoot
    Copy-Item -Force (Resolve-RepoPath "freeADFSOtp.sln") $bundleRoot

    New-ZipFromDirectory -SourceDirectory $bundleRoot -ZipFilePath (Join-Path $zipRoot "$PackagePrefix-complete.zip")
}

Write-Host "ZIP packages generated in: $zipRoot"
Get-ChildItem $zipRoot -Filter *.zip | Select-Object Name, Length | Format-Table -AutoSize
