param(
    [Parameter(Mandatory = $false)]
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$rootPath = "HKLM:\SOFTWARE\FreeAdfsOtp"
$adfsPath = Join-Path $rootPath "AdfsConnector"
$apiPath = Join-Path $rootPath "LocalApi"

function Get-RegistrySection {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $item = Get-ItemProperty -Path $Path
    $excluded = @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider")

    $values = @{}
    foreach ($p in $item.PSObject.Properties) {
        if ($excluded -contains $p.Name) {
            continue
        }

        $values[$p.Name] = $p.Value
    }

    return [pscustomobject]$values
}

$result = [ordered]@{
    Root = $rootPath
    AdfsConnector = Get-RegistrySection -Path $adfsPath
    LocalApi = Get-RegistrySection -Path $apiPath
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    exit 0
}

Write-Host "Registry root: $($result.Root)"

if ($null -eq $result.AdfsConnector) {
    Write-Host "[AdfsConnector] Not found"
}
else {
    Write-Host "[AdfsConnector]"
    $result.AdfsConnector.PSObject.Properties | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0} = {1}" -f $_.Name, $_.Value)
    }
}

if ($null -eq $result.LocalApi) {
    Write-Host "[LocalApi] Not found"
}
else {
    Write-Host "[LocalApi]"
    $result.LocalApi.PSObject.Properties | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0} = {1}" -f $_.Name, $_.Value)
    }
}
