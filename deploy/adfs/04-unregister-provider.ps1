param(
    [Parameter(Mandatory = $true)]
    [string]$ProviderName,

    [Parameter(Mandatory = $false)]
    [switch]$RestartAdfsService
)

$ErrorActionPreference = "Stop"

$existing = Get-AdfsAuthenticationProvider | Where-Object { $_.Name -eq $ProviderName }
if (-not $existing) {
    Write-Host "Provider not found: $ProviderName"
    return
}

Unregister-AdfsAuthenticationProvider -Name $ProviderName

if ($RestartAdfsService) {
    Restart-Service adfssrv -Force
}

Write-Host "Provider unregistered: $ProviderName"
