param(
    [Parameter(Mandatory = $true)]
    [string]$AdapterDllPath,

    [Parameter(Mandatory = $false)]
    [string]$GacutilPath = "C:\Tools\gacutil.exe",

    [Parameter(Mandatory = $false)]
    [switch]$UsePublishApiFallback = $true
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $AdapterDllPath)) {
    throw "Adapter dll not found: $AdapterDllPath"
}

$adapterFullPath = (Resolve-Path $AdapterDllPath).Path

Write-Host "Installing adapter in GAC..."
if (Test-Path $GacutilPath) {
    & $GacutilPath /if $adapterFullPath
}
elseif ($UsePublishApiFallback) {
    # Fallback when gacutil is not present on AD FS hosts.
    Add-Type -AssemblyName System.EnterpriseServices
    $publish = New-Object System.EnterpriseServices.Internal.Publish
    $publish.GacInstall($adapterFullPath)
}
else {
    throw "gacutil.exe not found: $GacutilPath"
}

Write-Host "Installed in GAC: $adapterFullPath"
