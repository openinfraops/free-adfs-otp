param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Set", "Test", "Read", "Help")]
    [string]$Action = "Help",

    [Parameter(Mandatory = $false)]
    [string]$Path = "C:\ProgramData\FreeAdfsOtp\secrets\secret.dpapi.txt",

    [Parameter(Mandatory = $false)]
    [string]$Secret = "",

    [Parameter(Mandatory = $false)]
    [switch]$PromptSecret,

    [Parameter(Mandatory = $false)]
    [switch]$Overwrite,

    [Parameter(Mandatory = $false)]
    [switch]$RevealSecret,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedSecret = ""
)

$ErrorActionPreference = "Stop"

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$SecureValue)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Protect-SecretText {
    param([string]$PlainText)

    if ([string]::IsNullOrWhiteSpace($PlainText)) {
        throw "Secret cannot be empty."
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-SecretText {
    param([string]$PayloadBase64)

    if ([string]::IsNullOrWhiteSpace($PayloadBase64)) {
        throw "DPAPI payload is empty."
    }

    $payload = [Convert]::FromBase64String($PayloadBase64)
    $raw = [Security.Cryptography.ProtectedData]::Unprotect($payload, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($raw)
}

function Get-SecretFromInput {
    if (-not [string]::IsNullOrWhiteSpace($Secret)) {
        return $Secret
    }

    if ($PromptSecret) {
        $secure = Read-Host "Secret value" -AsSecureString
        return (Convert-SecureStringToPlainText -SecureValue $secure)
    }

    throw "Provide -Secret or -PromptSecret."
}

function Ensure-ParentDirectory {
    param([string]$FilePath)

    $parent = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Show-Help {
@"
Manage-FreeAdfsOtpDpapiSecret.ps1

Actions:
  -Action Set   : Encrypt secret with DPAPI LocalMachine and write payload file
  -Action Test  : Validate that payload file can be decrypted on this machine
  -Action Read  : Read/decrypt payload (prints only with -RevealSecret)
  -Action Help  : Show this help

Examples:
  powershell -ExecutionPolicy Bypass -File .\deploy\security\Manage-FreeAdfsOtpDpapiSecret.ps1 -Action Set -Path "C:\ProgramData\FreeAdfsOtp\secrets\master-key.dpapi.txt" -PromptSecret -Overwrite

  powershell -ExecutionPolicy Bypass -File .\deploy\security\Manage-FreeAdfsOtpDpapiSecret.ps1 -Action Test -Path "C:\ProgramData\FreeAdfsOtp\secrets\master-key.dpapi.txt"

  powershell -ExecutionPolicy Bypass -File .\deploy\security\Manage-FreeAdfsOtpDpapiSecret.ps1 -Action Read -Path "C:\ProgramData\FreeAdfsOtp\secrets\admin-apikey.dpapi.txt" -RevealSecret
"@ | Write-Host
}

$resolvedPath = [Environment]::ExpandEnvironmentVariables($Path)
if (-not [System.IO.Path]::IsPathRooted($resolvedPath)) {
    $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
}

switch ($Action) {
    "Help" {
        Show-Help
        break
    }

    "Set" {
        if ((Test-Path $resolvedPath) -and -not $Overwrite) {
            throw "File already exists: $resolvedPath. Use -Overwrite to replace it."
        }

        $secretValue = Get-SecretFromInput
        $payload = Protect-SecretText -PlainText $secretValue
        Ensure-ParentDirectory -FilePath $resolvedPath
        Set-Content -Path $resolvedPath -Value $payload -Encoding UTF8
        Write-Host "DPAPI secret payload saved: $resolvedPath"
        break
    }

    "Test" {
        if (-not (Test-Path $resolvedPath)) {
            throw "File not found: $resolvedPath"
        }

        $payload = (Get-Content -Path $resolvedPath -Raw).Trim()
        $decrypted = Unprotect-SecretText -PayloadBase64 $payload

        if ([string]::IsNullOrWhiteSpace($decrypted)) {
            throw "Secret payload decrypted to an empty value."
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedSecret) -and $decrypted -ne $ExpectedSecret) {
            throw "Decrypted secret does not match ExpectedSecret."
        }

        Write-Host "DPAPI secret payload is valid on this machine: $resolvedPath"
        break
    }

    "Read" {
        if (-not (Test-Path $resolvedPath)) {
            throw "File not found: $resolvedPath"
        }

        $payload = (Get-Content -Path $resolvedPath -Raw).Trim()
        $decrypted = Unprotect-SecretText -PayloadBase64 $payload

        Write-Host "DPAPI payload file: $resolvedPath"
        Write-Host ("Decrypted secret length: {0}" -f $decrypted.Length)

        if ($RevealSecret) {
            Write-Host "Decrypted secret value:" 
            Write-Host $decrypted
        }
        else {
            Write-Host "Secret value is hidden by default. Use -RevealSecret to print it."
        }

        break
    }
}
