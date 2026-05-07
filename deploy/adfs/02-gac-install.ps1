param(
    [Parameter(Mandatory = $true)]
    [string]$AdapterDllPath,

    [Parameter(Mandatory = $false)]
    [string]$GacutilPath = "C:\Tools\gacutil.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $AdapterDllPath)) {
    throw "Adapter dll not found: $AdapterDllPath"
}

if (-not (Test-Path $GacutilPath)) {
    throw "gacutil.exe not found: $GacutilPath"
}

$adapterFullPath = (Resolve-Path $AdapterDllPath).Path

Write-Host "Installing adapter in GAC..."
& $GacutilPath /if $adapterFullPath

Write-Host "Installed in GAC: $adapterFullPath"
