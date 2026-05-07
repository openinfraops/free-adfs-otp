param(
    [Parameter(Mandatory = $true)]
    [string]$ProviderName,

    [Parameter(Mandatory = $false)]
    [switch]$RequireExternalOnly = $true,

    [Parameter(Mandatory = $false)]
    [switch]$ApplyGlobalRule = $true
)

$ErrorActionPreference = "Stop"

$current = Get-AdfsGlobalAuthenticationPolicy
$providers = @($current.AdditionalAuthenticationProvider)

if ($providers -notcontains $ProviderName) {
    $providers += $ProviderName
    Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider $providers
}

if ($ApplyGlobalRule) {
    if ($RequireExternalOnly) {
        $rule = 'c:[type == "http://schemas.microsoft.com/ws/2012/01/insidecorporatenetwork", value == "false"] => issue(type = "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod", value = "http://schemas.microsoft.com/claims/multipleauthn" );'
    }
    else {
        $rule = '=> issue(type = "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod", value = "http://schemas.microsoft.com/claims/multipleauthn" );'
    }

    Set-AdfsAdditionalAuthenticationRule -AdditionalAuthenticationRules $rule
}

Write-Host "MFA policy configured for provider: $ProviderName"
Get-AdfsGlobalAuthenticationPolicy | Format-List
Get-AdfsAdditionalAuthenticationRule | Format-List
