param(
    [Parameter(Mandatory = $true)]
    [string]$AdapterDllPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $AdapterDllPath)) {
    throw "Adapter dll not found: $AdapterDllPath"
}

$adapterFullPath = (Resolve-Path $AdapterDllPath).Path

Write-Host "Installing adapter in GAC..."
Add-Type -AssemblyName System.EnterpriseServices
$publish = New-Object System.EnterpriseServices.Internal.Publish
$publish.GacInstall($adapterFullPath)

Write-Host "Installed in GAC: $adapterFullPath"
