param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServer,

    [Parameter(Mandatory = $false)]
    [string]$SqlDatabase = "FreeAdfsOtp",

    [Parameter(Mandatory = $false)]
    [switch]$UseIntegratedSecurity,

    [Parameter(Mandatory = $false)]
    [string]$SqlUser,

    [Parameter(Mandatory = $false)]
    [string]$SqlPassword,

    [Parameter(Mandatory = $false)]
    [string]$ScriptsRoot = ".\sql",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    return (Join-Path $repoRoot $Path)
}

function Get-SqlExecutor {
    if (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue) {
        return "sqlcmd"
    }

    if (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
        return "invoke-sqlcmd"
    }

    throw "Neither sqlcmd.exe nor Invoke-Sqlcmd is available. Install SQL Server command-line tools or SqlServer PowerShell module."
}

function New-AuthParameters {
    param([string]$Executor)

    if ($UseIntegratedSecurity) {
        if ($Executor -eq "sqlcmd") {
            return @("-E")
        }

        return @{}
    }

    if ([string]::IsNullOrWhiteSpace($SqlUser)) {
        throw "SqlUser is required when integrated security is disabled."
    }

    if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
        throw "SqlPassword is required when integrated security is disabled."
    }

    if ($Executor -eq "sqlcmd") {
        return @("-U", $SqlUser, "-P", $SqlPassword)
    }

    return @{
        Username = $SqlUser
        Password = $SqlPassword
    }
}

function Invoke-SqlText {
    param(
        [string]$Executor,
        [string]$Database,
        [string]$Query,
        [string]$Description
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] SQL text: $Description"
        return
    }

    $auth = New-AuthParameters -Executor $Executor

    if ($Executor -eq "sqlcmd") {
        $args = @("-S", $SqlServer, "-d", $Database, "-b", "-Q", $Query)
        $args += $auth
        & sqlcmd.exe @args
        if ($LASTEXITCODE -ne 0) {
            throw "sqlcmd failed while running '$Description' with exit code $LASTEXITCODE."
        }
        return
    }

    $invokeParams = @{
        ServerInstance = $SqlServer
        Database = $Database
        Query = $Query
        ErrorAction = "Stop"
    }

    if (-not $UseIntegratedSecurity) {
        $invokeParams["Username"] = $auth.Username
        $invokeParams["Password"] = $auth.Password
    }

    Invoke-Sqlcmd @invokeParams | Out-Null
}

function Invoke-SqlFileStep {
    param(
        [string]$Executor,
        [string]$Database,
        [string]$FilePath,
        [string]$Description
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] SQL file: $Description ($FilePath)"
        return
    }

    $auth = New-AuthParameters -Executor $Executor

    if ($Executor -eq "sqlcmd") {
        $args = @("-S", $SqlServer, "-d", $Database, "-b", "-i", $FilePath)
        $args += $auth
        & sqlcmd.exe @args
        if ($LASTEXITCODE -ne 0) {
            throw "sqlcmd failed while running '$Description' with exit code $LASTEXITCODE."
        }
        return
    }

    $invokeParams = @{
        ServerInstance = $SqlServer
        Database = $Database
        InputFile = $FilePath
        ErrorAction = "Stop"
    }

    if (-not $UseIntegratedSecurity) {
        $invokeParams["Username"] = $auth.Username
        $invokeParams["Password"] = $auth.Password
    }

    Invoke-Sqlcmd @invokeParams | Out-Null
}

if ([string]::IsNullOrWhiteSpace($SqlServer)) {
    throw "SqlServer is required."
}

$scriptsRootPath = Resolve-RepoPath $ScriptsRoot
$initScriptPath = Join-Path $scriptsRootPath "001_init.sql"
$pendingScriptPath = Join-Path $scriptsRootPath "002_pending_enrollments.sql"

if (-not (Test-Path $initScriptPath)) {
    throw "SQL script not found: $initScriptPath"
}

if (-not (Test-Path $pendingScriptPath)) {
    throw "SQL script not found: $pendingScriptPath"
}

$executor = Get-SqlExecutor
Write-Host "Using SQL executor: $executor"

$dbNameForBracket = $SqlDatabase.Replace("]", "]]" )
$dbNameForLiteral = $SqlDatabase.Replace("'", "''")
$ensureDbQuery = "IF DB_ID(N'$dbNameForLiteral') IS NULL CREATE DATABASE [$dbNameForBracket];"

Invoke-SqlText -Executor $executor -Database "master" -Query $ensureDbQuery -Description "Ensure database exists"
Invoke-SqlFileStep -Executor $executor -Database $SqlDatabase -FilePath $initScriptPath -Description "Initialize schema"
Invoke-SqlFileStep -Executor $executor -Database $SqlDatabase -FilePath $pendingScriptPath -Description "Initialize pending enrollments"

Write-Host "SQL initialization completed for database '$SqlDatabase'."
