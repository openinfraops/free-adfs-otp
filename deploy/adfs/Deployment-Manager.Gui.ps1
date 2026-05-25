Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$RegistryRootPath = "HKLM:\SOFTWARE\FreeAdfsOtp"
$AdfsConnectorRegistryPath = Join-Path $RegistryRootPath "AdfsConnector"
$LocalApiRegistryPath = Join-Path $RegistryRootPath "LocalApi"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-SelfAsAdministrator {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Unable to self-elevate because PSCommandPath is empty. Run the script via -File."
    }

    $scriptPath = Normalize-WindowsPath $PSCommandPath
    $processArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`""
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList ($processArgs -join " ") -Verb RunAs -WorkingDirectory (Get-Location).Path | Out-Null
}

function ConvertTo-Psd1SafeString {
    param([string]$Value)
    if ($null -eq $Value) {
        return ""
    }

    return ($Value -replace "'", "''")
}

function Normalize-WindowsPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $normalized = $Path.Trim().Replace('/', '\\')
    try {
        if ([System.IO.Path]::IsPathRooted($normalized)) {
            return [System.IO.Path]::GetFullPath($normalized)
        }
    }
    catch {
        # Keep best-effort normalized path.
    }

    return $normalized
}

function ConvertTo-Psd1BoolString {
    param([bool]$Value)

    if ($Value) {
        return "`$true"
    }

    return "`$false"
}

function Resolve-RepoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $Path = Normalize-WindowsPath $Path

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    return (Normalize-WindowsPath (Join-Path $repoRoot $Path))
}

function Get-RegistrySection {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $item = Get-ItemProperty -Path $Path
    $excluded = @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider")

    $values = @{}
    foreach ($prop in $item.PSObject.Properties) {
        if ($excluded -contains $prop.Name) {
            continue
        }

        $values[$prop.Name] = $prop.Value
    }

    return [pscustomobject]$values
}

function Show-SelectFilePath {
    param(
        [string]$InitialPath,
        [string]$Title,
        [string]$Filter = "All files (*.*)|*.*",
        [switch]$SaveDialog
    )

    $dialog = if ($SaveDialog) {
        New-Object System.Windows.Forms.SaveFileDialog
    }
    else {
        New-Object System.Windows.Forms.OpenFileDialog
    }

    $dialog.Title = $Title
    $dialog.Filter = $Filter

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        try {
            $fullPath = [System.IO.Path]::GetFullPath($InitialPath)
            $directory = [System.IO.Path]::GetDirectoryName($fullPath)
            $fileName = [System.IO.Path]::GetFileName($fullPath)

            if (-not [string]::IsNullOrWhiteSpace($directory) -and (Test-Path $directory)) {
                $dialog.InitialDirectory = $directory
            }

            if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                $dialog.FileName = $fileName
            }
        }
        catch {
            # Best effort only for initial dialog position.
        }
    }

    $selected = $null
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selected = Normalize-WindowsPath $dialog.FileName
    }

    $dialog.Dispose()
    return $selected
}

function Show-SelectFolderPath {
    param(
        [string]$InitialPath,
        [string]$Description = "Select folder"
    )

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true

    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path $InitialPath)) {
        $dialog.SelectedPath = $InitialPath
    }

    $selected = $null
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selected = Normalize-WindowsPath $dialog.SelectedPath
    }

    $dialog.Dispose()
    return $selected
}

function Write-AdfsNodeConfigFile {
    param(
        [string]$Path,
        [hashtable]$Config
    )

    $content = @"
@{
    ProviderName = 'Free-ADFS-OTP'
    TypeName = ''
    Mode = '$(ConvertTo-Psd1SafeString $Config.Mode)'
    AdapterZipPath = '$(ConvertTo-Psd1SafeString $Config.AdapterZipPath)'
    SqlConnectionString = '$(ConvertTo-Psd1SafeString $Config.SqlConnectionString)'
    SecretMasterKeyBase64 = '$(ConvertTo-Psd1SafeString $Config.SecretMasterKeyBase64)'
    ApiBaseUrl = '$(ConvertTo-Psd1SafeString $Config.ApiBaseUrl)'
    EnrollmentPortalBaseUrl = '$(ConvertTo-Psd1SafeString $Config.EnrollmentPortalBaseUrl)'
    RequireExternalOnly = $(ConvertTo-Psd1BoolString ([bool]$Config.RequireExternalOnly))
    ApplyGlobalRule = $(ConvertTo-Psd1BoolString ([bool]$Config.ApplyGlobalRule))
    ForceReregister = $(ConvertTo-Psd1BoolString ([bool]$Config.ForceReregister))
    RestartAdfsService = $(ConvertTo-Psd1BoolString ([bool]$Config.RestartAdfsService))
}
"@

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Set-Content -Path $Path -Value $content -Encoding UTF8
}

function Write-LocalApiConfigFile {
    param(
        [string]$Path,
        [hashtable]$Config
    )

    $content = @"
@{
    ApiZipPath = '$(ConvertTo-Psd1SafeString $Config.ApiZipPath)'
    InstallRoot = '$(ConvertTo-Psd1SafeString $Config.InstallRoot)'
    ServiceName = '$(ConvertTo-Psd1SafeString $Config.ServiceName)'
    DotnetPath = '$(ConvertTo-Psd1SafeString $Config.DotnetPath)'
    ListenUrl = '$(ConvertTo-Psd1SafeString $Config.ListenUrl)'

    OtpSqlConnectionString = '$(ConvertTo-Psd1SafeString $Config.OtpSqlConnectionString)'
    MasterKeyBase64 = '$(ConvertTo-Psd1SafeString $Config.MasterKeyBase64)'
    AdminApiKey = '$(ConvertTo-Psd1SafeString $Config.AdminApiKey)'

    LocalCacheEnabled = $(ConvertTo-Psd1BoolString ([bool]$Config.LocalCacheEnabled))
    AllowSqlFallbackForValidation = $(ConvertTo-Psd1BoolString ([bool]$Config.AllowSqlFallbackForValidation))
    LocalCacheDatabasePath = '$(ConvertTo-Psd1SafeString $Config.LocalCacheDatabasePath)'
    PeriodicSyncEnabled = $(ConvertTo-Psd1BoolString ([bool]$Config.PeriodicSyncEnabled))
    PeriodicSyncIntervalSeconds = $($Config.PeriodicSyncIntervalSeconds)

    ServiceAccount = '$(ConvertTo-Psd1SafeString $Config.ServiceAccount)'
    ServiceAccountPassword = '$(ConvertTo-Psd1SafeString $Config.ServiceAccountPassword)'
}
"@

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Set-Content -Path $Path -Value $content -Encoding UTF8
}

function Try-ImportPsd1Config {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $null
    }

    $resolvedPath = Resolve-RepoPath $ConfigPath
    if (-not (Test-Path $resolvedPath)) {
        return $null
    }

    try {
        return Import-PowerShellDataFile -Path $resolvedPath
    }
    catch {
        return $null
    }
}

function Show-AdfsConfigDialog {
    param([string]$InitialConfigPath)

    $recommendedConfigPath = if ([string]::IsNullOrWhiteSpace($InitialConfigPath)) {
        "C:\Program Files\FreeAdfsOtp\config\adfs-node.config.psd1"
    }
    else {
        $InitialConfigPath
    }

    $existingConfig = Try-ImportPsd1Config -ConfigPath $recommendedConfigPath

    $modeDefault = "SqlDirect"
    if ($existingConfig -and $existingConfig.ContainsKey("Mode") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.Mode)) {
        $modeDefault = [string]$existingConfig.Mode
    }

    $adapterZipDefault = ".\\artifacts\\packages\\zip\\freeADFSOtp-adfs-node-package.zip"
    if ($existingConfig -and $existingConfig.ContainsKey("AdapterZipPath") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.AdapterZipPath)) {
        $adapterZipDefault = [string]$existingConfig.AdapterZipPath
    }

    $sqlConnectionDefault = "Server=localhost;Database=FreeAdfsOtp;Integrated Security=true;TrustServerCertificate=true;Connect Timeout=3;ConnectRetryCount=0;Pooling=true;Min Pool Size=10;Max Pool Size=200;Application Name=freeADFSOtp-ADFS;"
    if ($existingConfig -and $existingConfig.ContainsKey("SqlConnectionString") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.SqlConnectionString)) {
        $sqlConnectionDefault = [string]$existingConfig.SqlConnectionString
    }

    $secretDefault = ""
    if ($existingConfig -and $existingConfig.ContainsKey("SecretMasterKeyBase64") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.SecretMasterKeyBase64)) {
        $secretDefault = [string]$existingConfig.SecretMasterKeyBase64
    }

    $apiBaseDefault = "https://localhost:7043"
    if ($existingConfig -and $existingConfig.ContainsKey("ApiBaseUrl") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.ApiBaseUrl)) {
        $apiBaseDefault = [string]$existingConfig.ApiBaseUrl
    }

    $enrollmentPortalDefault = "https://otp-enroll.contoso.local/enroll"
    if ($existingConfig -and $existingConfig.ContainsKey("EnrollmentPortalBaseUrl") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.EnrollmentPortalBaseUrl)) {
        $enrollmentPortalDefault = [string]$existingConfig.EnrollmentPortalBaseUrl
    }

    $requireExternalOnlyDefault = $true
    if ($existingConfig -and $existingConfig.ContainsKey("RequireExternalOnly")) {
        $requireExternalOnlyDefault = [bool]$existingConfig.RequireExternalOnly
    }

    $applyGlobalRuleDefault = $true
    if ($existingConfig -and $existingConfig.ContainsKey("ApplyGlobalRule")) {
        $applyGlobalRuleDefault = [bool]$existingConfig.ApplyGlobalRule
    }

    $forceReregisterDefault = $true
    if ($existingConfig -and $existingConfig.ContainsKey("ForceReregister")) {
        $forceReregisterDefault = [bool]$existingConfig.ForceReregister
    }

    $restartAdfsDefault = $true
    if ($existingConfig -and $existingConfig.ContainsKey("RestartAdfsService")) {
        $restartAdfsDefault = [bool]$existingConfig.RestartAdfsService
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "ADFS config editor"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(860, 620)
    $dialog.MinimumSize = New-Object System.Drawing.Size(860, 620)

    $lblConfigPath = New-Object System.Windows.Forms.Label
    $lblConfigPath.Text = "ConfigPath (reutilisable pour setup/update)"
    $lblConfigPath.Location = New-Object System.Drawing.Point -ArgumentList 20, 20
    $lblConfigPath.AutoSize = $true
    $dialog.Controls.Add($lblConfigPath)

    $tbConfigPath = New-Object System.Windows.Forms.TextBox
    $tbConfigPath.Location = New-Object System.Drawing.Point -ArgumentList 20, 40
    $tbConfigPath.Width = 660
    $tbConfigPath.Text = $recommendedConfigPath
    $dialog.Controls.Add($tbConfigPath)

    $btnBrowseConfigPath = New-Object System.Windows.Forms.Button
    $btnBrowseConfigPath.Text = "Browse..."
    $btnBrowseConfigPath.Location = New-Object System.Drawing.Point -ArgumentList 690, 38
    $btnBrowseConfigPath.Size = New-Object System.Drawing.Size(130, 26)
    $dialog.Controls.Add($btnBrowseConfigPath)

    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = "Mode"
    $lblMode.Location = New-Object System.Drawing.Point -ArgumentList 20, 78
    $lblMode.AutoSize = $true
    $dialog.Controls.Add($lblMode)

    $cbMode = New-Object System.Windows.Forms.ComboBox
    $cbMode.Location = New-Object System.Drawing.Point -ArgumentList 20, 98
    $cbMode.Width = 180
    $cbMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$cbMode.Items.Add("SqlDirect")
    [void]$cbMode.Items.Add("Api")
    if ($cbMode.Items.Contains($modeDefault)) {
        $cbMode.SelectedItem = $modeDefault
    }
    else {
        $cbMode.SelectedItem = "SqlDirect"
    }
    $dialog.Controls.Add($cbMode)

    $lblAdapterZipPath = New-Object System.Windows.Forms.Label
    $lblAdapterZipPath.Text = "AdapterZipPath"
    $lblAdapterZipPath.Location = New-Object System.Drawing.Point -ArgumentList 20, 138
    $lblAdapterZipPath.AutoSize = $true
    $dialog.Controls.Add($lblAdapterZipPath)

    $tbAdapterZipPath = New-Object System.Windows.Forms.TextBox
    $tbAdapterZipPath.Location = New-Object System.Drawing.Point -ArgumentList 20, 158
    $tbAdapterZipPath.Width = 660
    $tbAdapterZipPath.Text = $adapterZipDefault
    $dialog.Controls.Add($tbAdapterZipPath)

    $btnBrowseAdapterZipPath = New-Object System.Windows.Forms.Button
    $btnBrowseAdapterZipPath.Text = "Browse..."
    $btnBrowseAdapterZipPath.Location = New-Object System.Drawing.Point -ArgumentList 690, 156
    $btnBrowseAdapterZipPath.Size = New-Object System.Drawing.Size(130, 26)
    $dialog.Controls.Add($btnBrowseAdapterZipPath)

    $lblSqlConnectionString = New-Object System.Windows.Forms.Label
    $lblSqlConnectionString.Text = "SqlConnectionString (mode SqlDirect)"
    $lblSqlConnectionString.Location = New-Object System.Drawing.Point -ArgumentList 20, 196
    $lblSqlConnectionString.AutoSize = $true
    $dialog.Controls.Add($lblSqlConnectionString)

    $tbSqlConnectionString = New-Object System.Windows.Forms.TextBox
    $tbSqlConnectionString.Location = New-Object System.Drawing.Point -ArgumentList 20, 216
    $tbSqlConnectionString.Width = 800
    $tbSqlConnectionString.Text = $sqlConnectionDefault
    $dialog.Controls.Add($tbSqlConnectionString)

    $lblSecretMasterKey = New-Object System.Windows.Forms.Label
    $lblSecretMasterKey.Text = "SecretMasterKeyBase64 (mode SqlDirect)"
    $lblSecretMasterKey.Location = New-Object System.Drawing.Point -ArgumentList 20, 254
    $lblSecretMasterKey.AutoSize = $true
    $dialog.Controls.Add($lblSecretMasterKey)

    $tbSecretMasterKey = New-Object System.Windows.Forms.TextBox
    $tbSecretMasterKey.Location = New-Object System.Drawing.Point -ArgumentList 20, 274
    $tbSecretMasterKey.Width = 800
    $tbSecretMasterKey.Text = $secretDefault
    $dialog.Controls.Add($tbSecretMasterKey)

    $lblApiBaseUrl = New-Object System.Windows.Forms.Label
    $lblApiBaseUrl.Text = "ApiBaseUrl (mode Api)"
    $lblApiBaseUrl.Location = New-Object System.Drawing.Point -ArgumentList 20, 312
    $lblApiBaseUrl.AutoSize = $true
    $dialog.Controls.Add($lblApiBaseUrl)

    $tbApiBaseUrl = New-Object System.Windows.Forms.TextBox
    $tbApiBaseUrl.Location = New-Object System.Drawing.Point -ArgumentList 20, 332
    $tbApiBaseUrl.Width = 800
    $tbApiBaseUrl.Text = $apiBaseDefault
    $dialog.Controls.Add($tbApiBaseUrl)

    $lblEnrollmentPortal = New-Object System.Windows.Forms.Label
    $lblEnrollmentPortal.Text = "EnrollmentPortalBaseUrl"
    $lblEnrollmentPortal.Location = New-Object System.Drawing.Point -ArgumentList 20, 370
    $lblEnrollmentPortal.AutoSize = $true
    $dialog.Controls.Add($lblEnrollmentPortal)

    $tbEnrollmentPortal = New-Object System.Windows.Forms.TextBox
    $tbEnrollmentPortal.Location = New-Object System.Drawing.Point -ArgumentList 20, 390
    $tbEnrollmentPortal.Width = 800
    $tbEnrollmentPortal.Text = $enrollmentPortalDefault
    $dialog.Controls.Add($tbEnrollmentPortal)

    $chkRequireExternalOnly = New-Object System.Windows.Forms.CheckBox
    $chkRequireExternalOnly.Text = "RequireExternalOnly"
    $chkRequireExternalOnly.Location = New-Object System.Drawing.Point -ArgumentList 20, 430
    $chkRequireExternalOnly.AutoSize = $true
    $chkRequireExternalOnly.Checked = $requireExternalOnlyDefault
    $dialog.Controls.Add($chkRequireExternalOnly)

    $chkApplyGlobalRule = New-Object System.Windows.Forms.CheckBox
    $chkApplyGlobalRule.Text = "ApplyGlobalRule"
    $chkApplyGlobalRule.Location = New-Object System.Drawing.Point -ArgumentList 220, 430
    $chkApplyGlobalRule.AutoSize = $true
    $chkApplyGlobalRule.Checked = $applyGlobalRuleDefault
    $dialog.Controls.Add($chkApplyGlobalRule)

    $chkForceReregister = New-Object System.Windows.Forms.CheckBox
    $chkForceReregister.Text = "ForceReregister"
    $chkForceReregister.Location = New-Object System.Drawing.Point -ArgumentList 400, 430
    $chkForceReregister.AutoSize = $true
    $chkForceReregister.Checked = $forceReregisterDefault
    $dialog.Controls.Add($chkForceReregister)

    $chkRestartAdfs = New-Object System.Windows.Forms.CheckBox
    $chkRestartAdfs.Text = "RestartAdfsService"
    $chkRestartAdfs.Location = New-Object System.Drawing.Point -ArgumentList 580, 430
    $chkRestartAdfs.AutoSize = $true
    $chkRestartAdfs.Checked = $restartAdfsDefault
    $dialog.Controls.Add($chkRestartAdfs)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save config"
    $btnSave.Location = New-Object System.Drawing.Point -ArgumentList 20, 476
    $btnSave.Size = New-Object System.Drawing.Size(150, 34)
    $dialog.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point -ArgumentList 182, 476
    $btnCancel.Size = New-Object System.Drawing.Size(150, 34)
    $dialog.Controls.Add($btnCancel)

    $dialog.Tag = $null

    $refreshModeView = {
        $isSqlDirect = ($cbMode.SelectedItem -eq "SqlDirect")

        $lblSqlConnectionString.Enabled = $isSqlDirect
        $tbSqlConnectionString.Enabled = $isSqlDirect
        $lblSecretMasterKey.Enabled = $isSqlDirect
        $tbSecretMasterKey.Enabled = $isSqlDirect

        $lblApiBaseUrl.Enabled = -not $isSqlDirect
        $tbApiBaseUrl.Enabled = -not $isSqlDirect
    }

    $cbMode.Add_SelectedIndexChanged($refreshModeView)
    & $refreshModeView

    $btnBrowseConfigPath.Add_Click({
        $selected = Show-SelectFilePath -InitialPath $tbConfigPath.Text -Title "Select ADFS config file" -Filter "PowerShell Data File (*.psd1)|*.psd1|All files (*.*)|*.*" -SaveDialog
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $tbConfigPath.Text = $selected
        }
    })

    $btnBrowseAdapterZipPath.Add_Click({
        $selected = Show-SelectFilePath -InitialPath $tbAdapterZipPath.Text -Title "Select adapter ZIP package" -Filter "ZIP files (*.zip)|*.zip|All files (*.*)|*.*"
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $tbAdapterZipPath.Text = $selected
        }
    })

    $btnSave.Add_Click({
        if ([string]::IsNullOrWhiteSpace($tbConfigPath.Text) -or
            [string]::IsNullOrWhiteSpace($tbAdapterZipPath.Text) -or
            [string]::IsNullOrWhiteSpace($tbEnrollmentPortal.Text)) {
            [System.Windows.Forms.MessageBox]::Show("All required fields must be filled.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $selectedMode = [string]$cbMode.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selectedMode)) {
            [System.Windows.Forms.MessageBox]::Show("Mode is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if ($selectedMode -eq "SqlDirect") {
            if ([string]::IsNullOrWhiteSpace($tbSqlConnectionString.Text) -or [string]::IsNullOrWhiteSpace($tbSecretMasterKey.Text)) {
                [System.Windows.Forms.MessageBox]::Show("In SqlDirect mode, SqlConnectionString and SecretMasterKeyBase64 are required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
        }
        elseif ($selectedMode -eq "Api") {
            if ([string]::IsNullOrWhiteSpace($tbApiBaseUrl.Text)) {
                [System.Windows.Forms.MessageBox]::Show("In Api mode, ApiBaseUrl is required.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
        }

        $dialog.Tag = @{
            ConfigPath = $tbConfigPath.Text.Trim()
            Mode = $selectedMode
            AdapterZipPath = $tbAdapterZipPath.Text.Trim()
            SqlConnectionString = if ($selectedMode -eq "SqlDirect") { $tbSqlConnectionString.Text.Trim() } else { "" }
            SecretMasterKeyBase64 = if ($selectedMode -eq "SqlDirect") { $tbSecretMasterKey.Text.Trim() } else { "" }
            ApiBaseUrl = if ($selectedMode -eq "Api") { $tbApiBaseUrl.Text.Trim() } else { "" }
            EnrollmentPortalBaseUrl = $tbEnrollmentPortal.Text.Trim()
            RequireExternalOnly = $chkRequireExternalOnly.Checked
            ApplyGlobalRule = $chkApplyGlobalRule.Checked
            ForceReregister = $chkForceReregister.Checked
            RestartAdfsService = $chkRestartAdfs.Checked
        }

        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    $dialogResult = $dialog.ShowDialog()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.Tag
    }

    return $null
}

function Show-LocalApiConfigDialog {
    param([string]$InitialConfigPath)

    $recommendedConfigPath = if ([string]::IsNullOrWhiteSpace($InitialConfigPath)) {
        "C:\Program Files\FreeAdfsOtp\config\adfs-local-api.config.psd1"
    }
    else {
        $InitialConfigPath
    }

    $existingConfig = Try-ImportPsd1Config -ConfigPath $recommendedConfigPath

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Local API config editor"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(920, 690)
    $dialog.MinimumSize = New-Object System.Drawing.Size(920, 690)

    $labels = @(
        "ConfigPath",
        "ApiZipPath",
        "InstallRoot",
        "ServiceName",
        "DotnetPath",
        "ListenUrl",
        "OtpSqlConnectionString",
        "MasterKeyBase64",
        "AdminApiKey",
        "LocalCacheDatabasePath",
        "PeriodicSyncIntervalSeconds",
        "ServiceAccount",
        "ServiceAccountPassword"
    )

    $defaults = @(
        $recommendedConfigPath,
        ".\\artifacts\\packages\\zip\\freeADFSOtp-api.zip",
        "C:\\ProgramData\\FreeAdfsOtp\\Api",
        "FreeAdfsOtpApi",
        "C:\\Program Files\\dotnet\\dotnet.exe",
        "http://127.0.0.1:5180",
        "Server=localhost;Database=FreeAdfsOtp;Integrated Security=true;TrustServerCertificate=true;Connect Timeout=3;ConnectRetryCount=0;Pooling=true;Min Pool Size=10;Max Pool Size=200;Application Name=freeADFSOtp-LocalApi;",
        "",
        "",
        "cache/freeadfsotp-node-cache.db",
        "30",
        "LocalSystem",
        ""
    )

    if ($existingConfig) {
        if ($existingConfig.ContainsKey("ApiZipPath") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.ApiZipPath)) { $defaults[1] = [string]$existingConfig.ApiZipPath }
        if ($existingConfig.ContainsKey("InstallRoot") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.InstallRoot)) { $defaults[2] = [string]$existingConfig.InstallRoot }
        if ($existingConfig.ContainsKey("ServiceName") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.ServiceName)) { $defaults[3] = [string]$existingConfig.ServiceName }
        if ($existingConfig.ContainsKey("DotnetPath") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.DotnetPath)) { $defaults[4] = [string]$existingConfig.DotnetPath }
        if ($existingConfig.ContainsKey("ListenUrl") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.ListenUrl)) { $defaults[5] = [string]$existingConfig.ListenUrl }
        if ($existingConfig.ContainsKey("OtpSqlConnectionString") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.OtpSqlConnectionString)) { $defaults[6] = [string]$existingConfig.OtpSqlConnectionString }
        if ($existingConfig.ContainsKey("MasterKeyBase64") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.MasterKeyBase64)) { $defaults[7] = [string]$existingConfig.MasterKeyBase64 }
        if ($existingConfig.ContainsKey("AdminApiKey") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.AdminApiKey)) { $defaults[8] = [string]$existingConfig.AdminApiKey }
        if ($existingConfig.ContainsKey("LocalCacheDatabasePath") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.LocalCacheDatabasePath)) { $defaults[9] = [string]$existingConfig.LocalCacheDatabasePath }
        if ($existingConfig.ContainsKey("PeriodicSyncIntervalSeconds")) { $defaults[10] = [string]$existingConfig.PeriodicSyncIntervalSeconds }
        if ($existingConfig.ContainsKey("ServiceAccount") -and -not [string]::IsNullOrWhiteSpace([string]$existingConfig.ServiceAccount)) { $defaults[11] = [string]$existingConfig.ServiceAccount }
        if ($existingConfig.ContainsKey("ServiceAccountPassword")) { $defaults[12] = [string]$existingConfig.ServiceAccountPassword }
    }

    $textBoxes = @{}
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $labels[$i]
        $label.Location = New-Object System.Drawing.Point -ArgumentList 20, (16 + ($i * 38))
        $label.AutoSize = $true
        $dialog.Controls.Add($label)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point -ArgumentList 250, (14 + ($i * 38))
        $tb.Width = 640
        $tb.Text = $defaults[$i]
        $dialog.Controls.Add($tb)
        $textBoxes[$labels[$i]] = $tb
    }

    $textBoxes["ConfigPath"].Width = 540
    $textBoxes["ApiZipPath"].Width = 540
    $textBoxes["InstallRoot"].Width = 540
    $textBoxes["DotnetPath"].Width = 540
    $textBoxes["LocalCacheDatabasePath"].Width = 540

    $btnBrowseLocalConfigPath = New-Object System.Windows.Forms.Button
    $btnBrowseLocalConfigPath.Text = "Browse..."
    $btnBrowseLocalConfigPath.Location = New-Object System.Drawing.Point -ArgumentList 800, ($textBoxes["ConfigPath"].Top - 1)
    $btnBrowseLocalConfigPath.Size = New-Object System.Drawing.Size(90, 26)
    $dialog.Controls.Add($btnBrowseLocalConfigPath)

    $btnBrowseApiZipPath = New-Object System.Windows.Forms.Button
    $btnBrowseApiZipPath.Text = "Browse..."
    $btnBrowseApiZipPath.Location = New-Object System.Drawing.Point -ArgumentList 800, ($textBoxes["ApiZipPath"].Top - 1)
    $btnBrowseApiZipPath.Size = New-Object System.Drawing.Size(90, 26)
    $dialog.Controls.Add($btnBrowseApiZipPath)

    $btnBrowseInstallRoot = New-Object System.Windows.Forms.Button
    $btnBrowseInstallRoot.Text = "Browse..."
    $btnBrowseInstallRoot.Location = New-Object System.Drawing.Point -ArgumentList 800, ($textBoxes["InstallRoot"].Top - 1)
    $btnBrowseInstallRoot.Size = New-Object System.Drawing.Size(90, 26)
    $dialog.Controls.Add($btnBrowseInstallRoot)

    $btnBrowseDotnetPath = New-Object System.Windows.Forms.Button
    $btnBrowseDotnetPath.Text = "Browse..."
    $btnBrowseDotnetPath.Location = New-Object System.Drawing.Point -ArgumentList 800, ($textBoxes["DotnetPath"].Top - 1)
    $btnBrowseDotnetPath.Size = New-Object System.Drawing.Size(90, 26)
    $dialog.Controls.Add($btnBrowseDotnetPath)

    $btnBrowseLocalCacheDbPath = New-Object System.Windows.Forms.Button
    $btnBrowseLocalCacheDbPath.Text = "Browse..."
    $btnBrowseLocalCacheDbPath.Location = New-Object System.Drawing.Point -ArgumentList 800, ($textBoxes["LocalCacheDatabasePath"].Top - 1)
    $btnBrowseLocalCacheDbPath.Size = New-Object System.Drawing.Size(90, 26)
    $dialog.Controls.Add($btnBrowseLocalCacheDbPath)

    $chkLocalCacheEnabled = New-Object System.Windows.Forms.CheckBox
    $chkLocalCacheEnabled.Text = "LocalCacheEnabled"
    $chkLocalCacheEnabled.Location = New-Object System.Drawing.Point -ArgumentList 20, 530
    $chkLocalCacheEnabled.AutoSize = $true
    $chkLocalCacheEnabled.Checked = if ($existingConfig -and $existingConfig.ContainsKey("LocalCacheEnabled")) { [bool]$existingConfig.LocalCacheEnabled } else { $true }
    $dialog.Controls.Add($chkLocalCacheEnabled)

    $chkAllowSqlFallback = New-Object System.Windows.Forms.CheckBox
    $chkAllowSqlFallback.Text = "AllowSqlFallbackForValidation"
    $chkAllowSqlFallback.Location = New-Object System.Drawing.Point -ArgumentList 180, 530
    $chkAllowSqlFallback.AutoSize = $true
    $chkAllowSqlFallback.Checked = if ($existingConfig -and $existingConfig.ContainsKey("AllowSqlFallbackForValidation")) { [bool]$existingConfig.AllowSqlFallbackForValidation } else { $true }
    $dialog.Controls.Add($chkAllowSqlFallback)

    $chkPeriodicSyncEnabled = New-Object System.Windows.Forms.CheckBox
    $chkPeriodicSyncEnabled.Text = "PeriodicSyncEnabled"
    $chkPeriodicSyncEnabled.Location = New-Object System.Drawing.Point -ArgumentList 430, 530
    $chkPeriodicSyncEnabled.AutoSize = $true
    $chkPeriodicSyncEnabled.Checked = if ($existingConfig -and $existingConfig.ContainsKey("PeriodicSyncEnabled")) { [bool]$existingConfig.PeriodicSyncEnabled } else { $true }
    $dialog.Controls.Add($chkPeriodicSyncEnabled)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save config"
    $btnSave.Location = New-Object System.Drawing.Point -ArgumentList 20, 572
    $btnSave.Size = New-Object System.Drawing.Size(150, 34)
    $dialog.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point -ArgumentList 182, 572
    $btnCancel.Size = New-Object System.Drawing.Size(150, 34)
    $dialog.Controls.Add($btnCancel)

    $dialog.Tag = $null

    $btnBrowseLocalConfigPath.Add_Click({
        $selected = Show-SelectFilePath -InitialPath $textBoxes["ConfigPath"].Text -Title "Select local API config file" -Filter "PowerShell Data File (*.psd1)|*.psd1|All files (*.*)|*.*" -SaveDialog
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $textBoxes["ConfigPath"].Text = $selected
        }
    })

    $btnBrowseApiZipPath.Add_Click({
        $selected = Show-SelectFilePath -InitialPath $textBoxes["ApiZipPath"].Text -Title "Select API ZIP package" -Filter "ZIP files (*.zip)|*.zip|All files (*.*)|*.*"
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $textBoxes["ApiZipPath"].Text = $selected
        }
    })

    $btnBrowseInstallRoot.Add_Click({
        $selected = Show-SelectFolderPath -InitialPath $textBoxes["InstallRoot"].Text -Description "Select API install root folder"
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $textBoxes["InstallRoot"].Text = $selected
        }
    })

    $btnBrowseDotnetPath.Add_Click({
        $selected = Show-SelectFilePath -InitialPath $textBoxes["DotnetPath"].Text -Title "Select dotnet executable" -Filter "dotnet executable (dotnet.exe)|dotnet.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*"
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $textBoxes["DotnetPath"].Text = $selected
        }
    })

    $btnBrowseLocalCacheDbPath.Add_Click({
        $selected = Show-SelectFilePath -InitialPath $textBoxes["LocalCacheDatabasePath"].Text -Title "Select local cache database path" -Filter "SQLite database (*.db)|*.db|All files (*.*)|*.*" -SaveDialog
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $textBoxes["LocalCacheDatabasePath"].Text = $selected
        }
    })

    $btnSave.Add_Click({
        $required = @(
            "ConfigPath", "ApiZipPath", "InstallRoot", "ServiceName", "DotnetPath", "ListenUrl",
            "OtpSqlConnectionString", "MasterKeyBase64", "AdminApiKey", "LocalCacheDatabasePath",
            "PeriodicSyncIntervalSeconds", "ServiceAccount"
        )

        foreach ($name in $required) {
            if ([string]::IsNullOrWhiteSpace($textBoxes[$name].Text)) {
                [System.Windows.Forms.MessageBox]::Show("Missing required field: $name", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
        }

        $interval = 0
        if (-not [int]::TryParse($textBoxes["PeriodicSyncIntervalSeconds"].Text.Trim(), [ref]$interval) -or $interval -le 0) {
            [System.Windows.Forms.MessageBox]::Show("PeriodicSyncIntervalSeconds must be an integer > 0.", "Validation", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $dialog.Tag = @{
            ConfigPath = $textBoxes["ConfigPath"].Text.Trim()
            ApiZipPath = $textBoxes["ApiZipPath"].Text.Trim()
            InstallRoot = $textBoxes["InstallRoot"].Text.Trim()
            ServiceName = $textBoxes["ServiceName"].Text.Trim()
            DotnetPath = $textBoxes["DotnetPath"].Text.Trim()
            ListenUrl = $textBoxes["ListenUrl"].Text.Trim()
            OtpSqlConnectionString = $textBoxes["OtpSqlConnectionString"].Text.Trim()
            MasterKeyBase64 = $textBoxes["MasterKeyBase64"].Text.Trim()
            AdminApiKey = $textBoxes["AdminApiKey"].Text.Trim()
            LocalCacheEnabled = $chkLocalCacheEnabled.Checked
            AllowSqlFallbackForValidation = $chkAllowSqlFallback.Checked
            LocalCacheDatabasePath = $textBoxes["LocalCacheDatabasePath"].Text.Trim()
            PeriodicSyncEnabled = $chkPeriodicSyncEnabled.Checked
            PeriodicSyncIntervalSeconds = $interval
            ServiceAccount = $textBoxes["ServiceAccount"].Text.Trim()
            ServiceAccountPassword = $textBoxes["ServiceAccountPassword"].Text.Trim()
        }

        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    $dialogResult = $dialog.ShowDialog()
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.Tag
    }

    return $null
}

function Add-LogLine {
    param(
        [System.Windows.Forms.TextBox]$OutputBox,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $OutputBox.AppendText("[$timestamp] $Message" + [Environment]::NewLine)
}

function Invoke-ManagedScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Arguments,
        [System.Windows.Forms.TextBox]$OutputBox,
        [string]$DisplayName
    )

    if (-not (Test-Path $ScriptPath)) {
        Add-LogLine -OutputBox $OutputBox -Message "Script not found: $ScriptPath"
        return
    }

    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add("-NoProfile")
    $argList.Add("-ExecutionPolicy")
    $argList.Add("Bypass")
    $argList.Add("-File")
    $argList.Add("`"$ScriptPath`"")

    foreach ($key in $Arguments.Keys) {
        $value = $Arguments[$key]
        if ($value -is [bool]) {
            if ($value) {
                $argList.Add("-$key")
            }

            continue
        }

        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            $argList.Add("-$key")
            $argList.Add("`"$value`"")
        }
    }

    $argumentText = $argList -join " "

    Add-LogLine -OutputBox $OutputBox -Message "Starting $DisplayName"
    Add-LogLine -OutputBox $OutputBox -Message "Command: powershell.exe $argumentText"

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "powershell.exe"
    $processInfo.Arguments = $argumentText
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        foreach ($line in ($stdout -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Add-LogLine -OutputBox $OutputBox -Message $line
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        foreach ($line in ($stderr -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Add-LogLine -OutputBox $OutputBox -Message "ERR: $line"
            }
        }
    }

    Add-LogLine -OutputBox $OutputBox -Message "$DisplayName finished with exit code $($process.ExitCode)"
    Add-LogLine -OutputBox $OutputBox -Message ""
}

if (-not (Test-IsAdministrator)) {
    try {
        Restart-SelfAsAdministrator
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to relaunch as administrator: $($_.Exception.Message)",
            "Elevation failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }

    exit
}

$scriptRoot = $PSScriptRoot
$setupAdfsScript = Join-Path $scriptRoot "Setup-AdfsOtpNode.ps1"
$setupLocalApiScript = Join-Path $scriptRoot "Setup-LocalApiService.ps1"
$updateAdfsScript = Join-Path $scriptRoot "Update-AdfsConnector.ps1"
$updateLocalApiScript = Join-Path $scriptRoot "Update-LocalApiService.ps1"
$getInfoScript = Join-Path $scriptRoot "Get-FreeAdfsOtpInstallInfo.ps1"
$sqlInitScript = Resolve-RepoPath ".\deploy\sql\Initialize-FreeAdfsOtpSql.ps1"
$guiIconPath = Join-Path $scriptRoot "assets\freeadfsotp.ico"

$form = New-Object System.Windows.Forms.Form
$form.Text = "freeADFSOtp - Deployment Manager"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 760)
$form.MinimumSize = New-Object System.Drawing.Size(980, 760)

if (Test-Path $guiIconPath) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($guiIconPath)
    }
    catch {
        # Keep default form icon if custom icon cannot be loaded.
    }
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"

$tabAdfs = New-Object System.Windows.Forms.TabPage
$tabAdfs.Text = "ADFS Connector"

$tabLocalApi = New-Object System.Windows.Forms.TabPage
$tabLocalApi.Text = "Local API"

$tabSql = New-Object System.Windows.Forms.TabPage
$tabSql.Text = "SQL"

$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = "Tools"

$tabs.TabPages.Add($tabAdfs)
$tabs.TabPages.Add($tabLocalApi)
$tabs.TabPages.Add($tabSql)
$tabs.TabPages.Add($tabTools)

$form.Controls.Add($tabs)

# Shared output panel
$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.ReadOnly = $true
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$outputBox.Dock = "Bottom"
$outputBox.Height = 280
$form.Controls.Add($outputBox)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 15000
$toolTip.InitialDelay = 300
$toolTip.ReshowDelay = 100
$toolTip.ShowAlways = $true

# ADFS tab controls
$adfsStatusLabel = New-Object System.Windows.Forms.Label
$adfsStatusLabel.Text = "Detected state: unknown"
$adfsStatusLabel.Location = New-Object System.Drawing.Point -ArgumentList 24, 8
$adfsStatusLabel.AutoSize = $true
$tabAdfs.Controls.Add($adfsStatusLabel)

$adfsConfigLabel = New-Object System.Windows.Forms.Label
$adfsConfigLabel.Text = "ConfigPath"
$adfsConfigLabel.Location = New-Object System.Drawing.Point -ArgumentList 24, 32
$adfsConfigLabel.AutoSize = $true
$tabAdfs.Controls.Add($adfsConfigLabel)

$adfsConfigText = New-Object System.Windows.Forms.TextBox
$adfsConfigText.Location = New-Object System.Drawing.Point -ArgumentList 24, 54
$adfsConfigText.Width = 500
$adfsConfigText.Text = "C:\Program Files\FreeAdfsOtp\config\adfs-node.config.psd1"
$tabAdfs.Controls.Add($adfsConfigText)

$btnBrowseAdfsConfig = New-Object System.Windows.Forms.Button
$btnBrowseAdfsConfig.Text = "Browse..."
$btnBrowseAdfsConfig.Location = New-Object System.Drawing.Point -ArgumentList 536, 52
$btnBrowseAdfsConfig.Size = New-Object System.Drawing.Size(96, 26)
$tabAdfs.Controls.Add($btnBrowseAdfsConfig)

$adfsSkipPolicy = New-Object System.Windows.Forms.CheckBox
$adfsSkipPolicy.Text = "Skip policy changes"
$adfsSkipPolicy.Location = New-Object System.Drawing.Point -ArgumentList 24, 92
$adfsSkipPolicy.AutoSize = $true
$tabAdfs.Controls.Add($adfsSkipPolicy)
$toolTip.SetToolTip($adfsSkipPolicy, "Run setup without applying global AD FS MFA policy changes.")

$adfsDryRun = New-Object System.Windows.Forms.CheckBox
$adfsDryRun.Text = "Dry run (simulation only)"
$adfsDryRun.Location = New-Object System.Drawing.Point -ArgumentList 24, 116
$adfsDryRun.AutoSize = $true
$tabAdfs.Controls.Add($adfsDryRun)
$toolTip.SetToolTip($adfsDryRun, "Preview commands only. No system changes are applied.")

$btnEditAdfsConfig = New-Object System.Windows.Forms.Button
$btnEditAdfsConfig.Text = "Create/Edit ADFS config"
$btnEditAdfsConfig.Location = New-Object System.Drawing.Point -ArgumentList 258, 98
$btnEditAdfsConfig.Size = New-Object System.Drawing.Size(220, 36)
$tabAdfs.Controls.Add($btnEditAdfsConfig)

$btnRefreshStatus = New-Object System.Windows.Forms.Button
$btnRefreshStatus.Text = "Refresh registry status"
$btnRefreshStatus.Location = New-Object System.Drawing.Point -ArgumentList 492, 98
$btnRefreshStatus.Size = New-Object System.Drawing.Size(200, 36)
$tabAdfs.Controls.Add($btnRefreshStatus)

$btnRunAdfsSetup = New-Object System.Windows.Forms.Button
$btnRunAdfsSetup.Text = "Install ADFS connector"
$btnRunAdfsSetup.Location = New-Object System.Drawing.Point -ArgumentList 24, 148
$btnRunAdfsSetup.Size = New-Object System.Drawing.Size(220, 36)
$tabAdfs.Controls.Add($btnRunAdfsSetup)

$btnRunAdfsUpdate = New-Object System.Windows.Forms.Button
$btnRunAdfsUpdate.Text = "Upgrade ADFS connector"
$btnRunAdfsUpdate.Location = New-Object System.Drawing.Point -ArgumentList 258, 148
$btnRunAdfsUpdate.Size = New-Object System.Drawing.Size(220, 36)
$tabAdfs.Controls.Add($btnRunAdfsUpdate)

$adfsHint = New-Object System.Windows.Forms.Label
$adfsHint.Text = "Interactive mode is replaced by the GUI config editor + registry detection."
$adfsHint.Location = New-Object System.Drawing.Point -ArgumentList 24, 186
$adfsHint.AutoSize = $true
$tabAdfs.Controls.Add($adfsHint)

# Local API tab controls
$apiStatusLabel = New-Object System.Windows.Forms.Label
$apiStatusLabel.Text = "Detected state: unknown"
$apiStatusLabel.Location = New-Object System.Drawing.Point -ArgumentList 24, 8
$apiStatusLabel.AutoSize = $true
$tabLocalApi.Controls.Add($apiStatusLabel)

$apiConfigLabel = New-Object System.Windows.Forms.Label
$apiConfigLabel.Text = "ConfigPath"
$apiConfigLabel.Location = New-Object System.Drawing.Point -ArgumentList 24, 32
$apiConfigLabel.AutoSize = $true
$tabLocalApi.Controls.Add($apiConfigLabel)

$apiConfigText = New-Object System.Windows.Forms.TextBox
$apiConfigText.Location = New-Object System.Drawing.Point -ArgumentList 24, 54
$apiConfigText.Width = 500
$apiConfigText.Text = "C:\Program Files\FreeAdfsOtp\config\adfs-local-api.config.psd1"
$tabLocalApi.Controls.Add($apiConfigText)

$btnBrowseApiConfig = New-Object System.Windows.Forms.Button
$btnBrowseApiConfig.Text = "Browse..."
$btnBrowseApiConfig.Location = New-Object System.Drawing.Point -ArgumentList 536, 52
$btnBrowseApiConfig.Size = New-Object System.Drawing.Size(96, 26)
$tabLocalApi.Controls.Add($btnBrowseApiConfig)

$apiDryRun = New-Object System.Windows.Forms.CheckBox
$apiDryRun.Text = "Dry run (simulation only)"
$apiDryRun.Location = New-Object System.Drawing.Point -ArgumentList 24, 92
$apiDryRun.AutoSize = $true
$tabLocalApi.Controls.Add($apiDryRun)
$toolTip.SetToolTip($apiDryRun, "Preview commands only. No system changes are applied.")

$btnEditApiConfig = New-Object System.Windows.Forms.Button
$btnEditApiConfig.Text = "Create/Edit Local API config"
$btnEditApiConfig.Location = New-Object System.Drawing.Point -ArgumentList 258, 86
$btnEditApiConfig.Size = New-Object System.Drawing.Size(250, 36)
$tabLocalApi.Controls.Add($btnEditApiConfig)

$btnRunApiSetup = New-Object System.Windows.Forms.Button
$btnRunApiSetup.Text = "Install Local API"
$btnRunApiSetup.Location = New-Object System.Drawing.Point -ArgumentList 24, 136
$btnRunApiSetup.Size = New-Object System.Drawing.Size(220, 36)
$tabLocalApi.Controls.Add($btnRunApiSetup)

$btnRunApiUpdate = New-Object System.Windows.Forms.Button
$btnRunApiUpdate.Text = "Upgrade Local API"
$btnRunApiUpdate.Location = New-Object System.Drawing.Point -ArgumentList 258, 136
$btnRunApiUpdate.Size = New-Object System.Drawing.Size(220, 36)
$tabLocalApi.Controls.Add($btnRunApiUpdate)

$apiHint = New-Object System.Windows.Forms.Label
$apiHint.Text = "Provide all values in the config editor, then run setup/update without Interactive."
$apiHint.Location = New-Object System.Drawing.Point -ArgumentList 24, 186
$apiHint.AutoSize = $true
$tabLocalApi.Controls.Add($apiHint)

# SQL tab controls
$sqlServerLabel = New-Object System.Windows.Forms.Label
$sqlServerLabel.Text = "SQL Server"
$sqlServerLabel.Location = New-Object System.Drawing.Point -ArgumentList 24, 24
$sqlServerLabel.AutoSize = $true
$tabSql.Controls.Add($sqlServerLabel)

$sqlServerText = New-Object System.Windows.Forms.TextBox
$sqlServerText.Location = New-Object System.Drawing.Point -ArgumentList 24, 46
$sqlServerText.Width = 300
$sqlServerText.Text = "localhost"
$tabSql.Controls.Add($sqlServerText)

$sqlDatabaseLabel = New-Object System.Windows.Forms.Label
$sqlDatabaseLabel.Text = "Database"
$sqlDatabaseLabel.Location = New-Object System.Drawing.Point -ArgumentList 344, 24
$sqlDatabaseLabel.AutoSize = $true
$tabSql.Controls.Add($sqlDatabaseLabel)

$sqlDatabaseText = New-Object System.Windows.Forms.TextBox
$sqlDatabaseText.Location = New-Object System.Drawing.Point -ArgumentList 344, 46
$sqlDatabaseText.Width = 220
$sqlDatabaseText.Text = "FreeAdfsOtp"
$tabSql.Controls.Add($sqlDatabaseText)

$sqlIntegratedSecurity = New-Object System.Windows.Forms.CheckBox
$sqlIntegratedSecurity.Text = "Use integrated security"
$sqlIntegratedSecurity.Location = New-Object System.Drawing.Point -ArgumentList 24, 82
$sqlIntegratedSecurity.AutoSize = $true
$sqlIntegratedSecurity.Checked = $true
$tabSql.Controls.Add($sqlIntegratedSecurity)

$sqlUserLabel = New-Object System.Windows.Forms.Label
$sqlUserLabel.Text = "SQL user"
$sqlUserLabel.Location = New-Object System.Drawing.Point -ArgumentList 24, 112
$sqlUserLabel.AutoSize = $true
$tabSql.Controls.Add($sqlUserLabel)

$sqlUserText = New-Object System.Windows.Forms.TextBox
$sqlUserText.Location = New-Object System.Drawing.Point -ArgumentList 24, 134
$sqlUserText.Width = 220
$tabSql.Controls.Add($sqlUserText)

$sqlPasswordLabel = New-Object System.Windows.Forms.Label
$sqlPasswordLabel.Text = "SQL password"
$sqlPasswordLabel.Location = New-Object System.Drawing.Point -ArgumentList 264, 112
$sqlPasswordLabel.AutoSize = $true
$tabSql.Controls.Add($sqlPasswordLabel)

$sqlPasswordText = New-Object System.Windows.Forms.TextBox
$sqlPasswordText.Location = New-Object System.Drawing.Point -ArgumentList 264, 134
$sqlPasswordText.Width = 220
$sqlPasswordText.UseSystemPasswordChar = $true
$tabSql.Controls.Add($sqlPasswordText)

$sqlDryRun = New-Object System.Windows.Forms.CheckBox
$sqlDryRun.Text = "Dry run (simulation only)"
$sqlDryRun.Location = New-Object System.Drawing.Point -ArgumentList 24, 172
$sqlDryRun.AutoSize = $true
$tabSql.Controls.Add($sqlDryRun)

$btnRunSqlInit = New-Object System.Windows.Forms.Button
$btnRunSqlInit.Text = "Initialize SQL (001 + 002)"
$btnRunSqlInit.Location = New-Object System.Drawing.Point -ArgumentList 24, 204
$btnRunSqlInit.Size = New-Object System.Drawing.Size(260, 36)
$tabSql.Controls.Add($btnRunSqlInit)

$sqlHint = New-Object System.Windows.Forms.Label
$sqlHint.Text = "Runs SQL initialization scripts and creates the database if needed."
$sqlHint.Location = New-Object System.Drawing.Point -ArgumentList 24, 252
$sqlHint.AutoSize = $true
$tabSql.Controls.Add($sqlHint)

# Tools tab controls
$btnGetInfo = New-Object System.Windows.Forms.Button
$btnGetInfo.Text = "Run Get-FreeAdfsOtpInstallInfo"
$btnGetInfo.Location = New-Object System.Drawing.Point -ArgumentList 24, 28
$btnGetInfo.Size = New-Object System.Drawing.Size(260, 36)
$tabTools.Controls.Add($btnGetInfo)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "Open deploy/adfs folder"
$btnOpenFolder.Location = New-Object System.Drawing.Point -ArgumentList 24, 80
$btnOpenFolder.Size = New-Object System.Drawing.Size(260, 36)
$tabTools.Controls.Add($btnOpenFolder)

$btnClearOutput = New-Object System.Windows.Forms.Button
$btnClearOutput.Text = "Clear output"
$btnClearOutput.Location = New-Object System.Drawing.Point -ArgumentList 24, 132
$btnClearOutput.Size = New-Object System.Drawing.Size(260, 36)
$tabTools.Controls.Add($btnClearOutput)

$toolHint = New-Object System.Windows.Forms.Label
$toolHint.Text = "Deployment state detection is based on HKLM:\SOFTWARE\FreeAdfsOtp."
$toolHint.Location = New-Object System.Drawing.Point -ArgumentList 24, 186
$toolHint.AutoSize = $true
$tabTools.Controls.Add($toolHint)

function Refresh-RegistryStatus {
    $adfsReg = Get-RegistrySection -Path $AdfsConnectorRegistryPath
    $apiReg = Get-RegistrySection -Path $LocalApiRegistryPath

    $adfsConfigCandidates = @()
    if ($adfsReg) {
        if ($adfsReg.PSObject.Properties["NodeConfigPath"]) { $adfsConfigCandidates += [string]$adfsReg.NodeConfigPath }
        if ($adfsReg.PSObject.Properties["UpdateConfigPath"]) { $adfsConfigCandidates += [string]$adfsReg.UpdateConfigPath }
    }

    $apiConfigCandidate = ""
    if ($apiReg -and $apiReg.PSObject.Properties["ConfigPath"]) {
        $apiConfigCandidate = [string]$apiReg.ConfigPath
    }

    $adfsDetected = $false
    foreach ($candidate in $adfsConfigCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $adfsDetected = $true
            $adfsConfigText.Text = Normalize-WindowsPath $candidate
            break
        }
    }

    $apiDetected = $false
    if (-not [string]::IsNullOrWhiteSpace($apiConfigCandidate)) {
        $apiDetected = $true
        $apiConfigText.Text = Normalize-WindowsPath $apiConfigCandidate
    }

    if ($adfsDetected) {
        $adfsStatusLabel.Text = "Detected state: deployed (registry key found)"
        $adfsStatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $adfsStatusLabel.Text = "Detected state: not deployed (registry key missing)"
        $adfsStatusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }

    if ($apiDetected) {
        $apiStatusLabel.Text = "Detected state: deployed (registry key found)"
        $apiStatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $apiStatusLabel.Text = "Detected state: not deployed (registry key missing)"
        $apiStatusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }

    Add-LogLine -OutputBox $outputBox -Message "Registry detection completed."
}

# Events
$btnRunAdfsSetup.Add_Click({
    $args = @{
        ConfigPath = $adfsConfigText.Text
        SkipPolicy = $adfsSkipPolicy.Checked
        DryRun = $adfsDryRun.Checked
    }

    Invoke-ManagedScript -ScriptPath $setupAdfsScript -Arguments $args -OutputBox $outputBox -DisplayName "Install ADFS connector"
})

$btnRunAdfsUpdate.Add_Click({
    $args = @{
        ConfigPath = $adfsConfigText.Text
        DryRun = $adfsDryRun.Checked
    }

    Invoke-ManagedScript -ScriptPath $updateAdfsScript -Arguments $args -OutputBox $outputBox -DisplayName "Upgrade ADFS connector"
})

$btnRunApiSetup.Add_Click({
    $args = @{
        ConfigPath = $apiConfigText.Text
        DryRun = $apiDryRun.Checked
    }

    Invoke-ManagedScript -ScriptPath $setupLocalApiScript -Arguments $args -OutputBox $outputBox -DisplayName "Install Local API"
})

$btnRunApiUpdate.Add_Click({
    $args = @{
        ConfigPath = $apiConfigText.Text
        DryRun = $apiDryRun.Checked
    }

    Invoke-ManagedScript -ScriptPath $updateLocalApiScript -Arguments $args -OutputBox $outputBox -DisplayName "Upgrade Local API"
})

$setSqlCredentialState = {
    $enabled = -not $sqlIntegratedSecurity.Checked
    $sqlUserText.Enabled = $enabled
    $sqlPasswordText.Enabled = $enabled
    $sqlUserLabel.Enabled = $enabled
    $sqlPasswordLabel.Enabled = $enabled
}

$sqlIntegratedSecurity.Add_CheckedChanged({
    & $setSqlCredentialState
})

$btnRunSqlInit.Add_Click({
    $args = @{
        SqlServer = $sqlServerText.Text
        SqlDatabase = $sqlDatabaseText.Text
        UseIntegratedSecurity = $sqlIntegratedSecurity.Checked
        SqlUser = $sqlUserText.Text
        SqlPassword = $sqlPasswordText.Text
        DryRun = $sqlDryRun.Checked
    }

    Invoke-ManagedScript -ScriptPath $sqlInitScript -Arguments $args -OutputBox $outputBox -DisplayName "Initialize SQL"
})

$btnGetInfo.Add_Click({
    Invoke-ManagedScript -ScriptPath $getInfoScript -Arguments @{} -OutputBox $outputBox -DisplayName "Get-FreeAdfsOtpInstallInfo"
})

$btnBrowseAdfsConfig.Add_Click({
    $selected = Show-SelectFilePath -InitialPath $adfsConfigText.Text -Title "Select ADFS config file" -Filter "PowerShell Data File (*.psd1)|*.psd1|All files (*.*)|*.*" -SaveDialog
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        $adfsConfigText.Text = $selected
    }
})

$btnBrowseApiConfig.Add_Click({
    $selected = Show-SelectFilePath -InitialPath $apiConfigText.Text -Title "Select local API config file" -Filter "PowerShell Data File (*.psd1)|*.psd1|All files (*.*)|*.*" -SaveDialog
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        $apiConfigText.Text = $selected
    }
})

$btnEditAdfsConfig.Add_Click({
    $config = Show-AdfsConfigDialog -InitialConfigPath $adfsConfigText.Text
    if ($null -eq $config) {
        return
    }

    try {
        $targetPath = Resolve-RepoPath $config.ConfigPath
        Write-AdfsNodeConfigFile -Path $targetPath -Config $config

        if (-not (Test-Path $targetPath)) {
            throw "Config file was not found after write operation."
        }

        $reloadedConfig = Try-ImportPsd1Config -ConfigPath $targetPath
        if ($null -eq $reloadedConfig) {
            throw "Config file was saved but could not be reloaded. Check PSD1 syntax and file permissions."
        }

        $adfsConfigText.Text = $targetPath
        Add-LogLine -OutputBox $outputBox -Message "ADFS config saved: $targetPath"
        [System.Windows.Forms.MessageBox]::Show(
            "ADFS config saved successfully:`n$targetPath",
            "Config saved",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Add-LogLine -OutputBox $outputBox -Message "ERR: Failed to save ADFS config - $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to save ADFS config:`n$($_.Exception.Message)",
            "Save failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$btnEditApiConfig.Add_Click({
    $config = Show-LocalApiConfigDialog -InitialConfigPath $apiConfigText.Text
    if ($null -eq $config) {
        return
    }

    try {
        $targetPath = Resolve-RepoPath $config.ConfigPath
        Write-LocalApiConfigFile -Path $targetPath -Config $config

        if (-not (Test-Path $targetPath)) {
            throw "Config file was not found after write operation."
        }

        $reloadedConfig = Try-ImportPsd1Config -ConfigPath $targetPath
        if ($null -eq $reloadedConfig) {
            throw "Config file was saved but could not be reloaded. Check PSD1 syntax and file permissions."
        }

        $apiConfigText.Text = $targetPath
        Add-LogLine -OutputBox $outputBox -Message "Local API config saved: $targetPath"
        [System.Windows.Forms.MessageBox]::Show(
            "Local API config saved successfully:`n$targetPath",
            "Config saved",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Add-LogLine -OutputBox $outputBox -Message "ERR: Failed to save Local API config - $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to save Local API config:`n$($_.Exception.Message)",
            "Save failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$btnRefreshStatus.Add_Click({
    Refresh-RegistryStatus
})

$btnOpenFolder.Add_Click({
    Start-Process explorer.exe -ArgumentList "`"$scriptRoot`""
})

$btnClearOutput.Add_Click({
    $outputBox.Clear()
})

& $setSqlCredentialState

Add-LogLine -OutputBox $outputBox -Message "Deployment Manager GUI ready."
Add-LogLine -OutputBox $outputBox -Message "Interactive mode is replaced by the GUI and config files."
Add-LogLine -OutputBox $outputBox -Message "Tip: start with DryRun to validate commands."

Refresh-RegistryStatus

[void]$form.ShowDialog()
