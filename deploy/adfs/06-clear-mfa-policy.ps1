param(
    [Parameter(Mandatory = $false)]
    [string]$ProviderName = ""
)

$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
    $current = Get-AdfsGlobalAuthenticationPolicy
    $providers = @($current.AdditionalAuthenticationProvider) | Where-Object { $_ -ne $ProviderName }
    Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider $providers
}

Set-AdfsAdditionalAuthenticationRule -AdditionalAuthenticationRules ""

Write-Host "MFA additional authentication rules cleared."
if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
    Write-Host "Provider removed from global additional auth list: $ProviderName"
}
