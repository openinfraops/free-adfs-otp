param(
    [Parameter(Mandatory = $true)]
    [string]$ProviderName,

    [Parameter(Mandatory = $true)]
    [string]$TypeName,

    [Parameter(Mandatory = $false)]
    [string]$ConfigurationFilePath = "",

    [Parameter(Mandatory = $false)]
    [switch]$RestartAdfsService
)

$ErrorActionPreference = "Stop"

$existing = Get-AdfsAuthenticationProvider | Where-Object { $_.Name -eq $ProviderName }
if ($existing) {
    throw "Provider already exists: $ProviderName. Unregister first or choose another name."
}

if ([string]::IsNullOrWhiteSpace($ConfigurationFilePath)) {
    Register-AdfsAuthenticationProvider -TypeName $TypeName -Name $ProviderName
}
else {
    if (-not (Test-Path $ConfigurationFilePath)) {
        throw "Configuration file not found: $ConfigurationFilePath"
    }

    Register-AdfsAuthenticationProvider -TypeName $TypeName -Name $ProviderName -ConfigurationFilePath $ConfigurationFilePath
}

if ($RestartAdfsService) {
    Restart-Service adfssrv -Force
}

Write-Host "Provider registered: $ProviderName"
Get-AdfsAuthenticationProvider | Format-Table Name, TypeName, Enabled -AutoSize
