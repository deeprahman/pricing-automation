<#
.SYNOPSIS
Runs custom SQL inside the n8n-postgres Docker container and saves the result locally.

.DESCRIPTION
This script connects to the AWS Lightsail Ubuntu server over SSH, executes SQL
inside the n8n-postgres Docker container using psql, and saves the output in a
local Windows log directory.

The SSH key path is already set to:

C:\Users\dprah\.ssh\aws-lightsail-mumbai.pem

You can still override it with -Key if needed.

USAGE 1: Run with default key and paste SQL in Notepad
powershell -ExecutionPolicy Bypass -File .\run-custom-postgres-sql-with-default-key.ps1

USAGE 2: Run an existing SQL file
powershell -ExecutionPolicy Bypass -File .\run-custom-postgres-sql-with-default-key.ps1 `
  -SqlFile ".\investigation.sql"

USAGE 3: Run inline SQL
powershell -ExecutionPolicy Bypass -File .\run-custom-postgres-sql-with-default-key.ps1 `
  -Sql "SELECT now(), current_database(), current_user;"

USAGE 4: Override SSH key path
powershell -ExecutionPolicy Bypass -File .\run-custom-postgres-sql-with-default-key.ps1 `
  -Key "X:\location\of\pem"

.DEFAULT SETTINGS
SSH user:       ubuntu
SSH host:       auto.palmwavestays.com
Container:      n8n-postgres
Postgres user:  n8n
Database:       auto_pws
Output folder:  Z:\Projects\pws_auto\temp\data-overflow testing\docker-log

.OUTPUT FILES
Each run creates a folder like:

Z:\Projects\pws_auto\temp\data-overflow testing\docker-log\custom_sql_20260517_123456\

Inside it:
- input.sql
- result.csv or result.txt
- stderr.txt
- docker_containers.txt
- summary.txt
#>

[CmdletBinding(DefaultParameterSetName = "Interactive")]
param (
    [string]$Key = "C:\Users\dprah\.ssh\aws-lightsail-mumbai.pem",

    [string]$SshUser = "ubuntu",

    [string]$SshHost = "auto.palmwavestays.com",

    [string]$ContainerName = "n8n-postgres",

    [string]$DbUser = "n8n",

    [string]$DbName = "auto_pws",

    [string]$DbPassword = "",

    [string]$OutDir = "Z:\Projects\pws_auto\temp\data-overflow testing\docker-log",

    [Parameter(ParameterSetName = "SqlFile")]
    [string]$SqlFile,

    [Parameter(ParameterSetName = "InlineSql")]
    [string]$Sql,

    [string]$ResultName = "custom_sql",

    [ValidateSet("csv", "table", "unaligned")]
    [string]$OutputFormat = "csv",

    [switch]$UseSudo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param ([string]$Message)

    Write-Host ""
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Quote-BashArg {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Join-BashCommand {
    param ([string[]]$Parts)

    return ($Parts | ForEach-Object { Quote-BashArg $_ }) -join " "
}

function New-SafeFileName {
    param ([string]$Name)

    $safe = $Name -replace '[\\/:*?"<>| ]+', '_'
    $safe = $safe.Trim("_")

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "custom_sql"
    }

    return $safe
}

if (-not (Test-Path $Key)) {
    throw "SSH key was not found: $Key"
}

$SafeResultName = New-SafeFileName -Name $ResultName
$RunTag = Get-Date -Format "yyyyMMdd_HHmmss"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$RunDir = Join-Path $OutDir "${SafeResultName}_$RunTag"
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$InputSqlFile = Join-Path $RunDir "input.sql"
$StdErrFile = Join-Path $RunDir "stderr.txt"
$SummaryFile = Join-Path $RunDir "summary.txt"
$ContainerListFile = Join-Path $RunDir "docker_containers.txt"

$ResultExtension = if ($OutputFormat -eq "csv") { "csv" } else { "txt" }
$ResultFile = Join-Path $RunDir "result.$ResultExtension"

$SshTarget = "$SshUser@$SshHost"
$SshArgs = @(
    "-i", $Key,
    "-o", "StrictHostKeyChecking=accept-new",
    $SshTarget
)

$DockerPartsPrefix = @()
if ($UseSudo) {
    $DockerPartsPrefix += "sudo"
}
$DockerPartsPrefix += "docker"

Write-Step "Preparing SQL input"

if ($PSCmdlet.ParameterSetName -eq "SqlFile") {
    if (-not (Test-Path $SqlFile)) {
        throw "SQL file was not found: $SqlFile"
    }

    Copy-Item -Path $SqlFile -Destination $InputSqlFile -Force
}
elseif ($PSCmdlet.ParameterSetName -eq "InlineSql") {
    $Sql | Set-Content -Path $InputSqlFile -Encoding UTF8
}
else {
    @"
-- Paste your SQL below, then save and close Notepad.

SELECT
    DATE_TRUNC('hour', created_at) AS hour,
    task_name,
    queue_name,
    status,
    COUNT(*) AS task_count
FROM task_queue
WHERE created_at >= '2026-05-16 06:00:00+06'
  AND created_at <= '2026-05-16 22:00:00+06'
GROUP BY 1, 2, 3, 4
ORDER BY hour, task_count DESC;

"@ | Set-Content -Path $InputSqlFile -Encoding UTF8

    Write-Host "Opening SQL file in Notepad:"
    Write-Host $InputSqlFile

    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$InputSqlFile`"" -Wait

    $RawSql = Get-Content -Raw -Path $InputSqlFile
    if ([string]::IsNullOrWhiteSpace($RawSql)) {
        throw "No SQL was provided. File is empty: $InputSqlFile"
    }
}

Write-Host "SQL saved to:"
Write-Host $InputSqlFile

Write-Step "Checking Docker containers on remote server"

$ListContainersParts = $DockerPartsPrefix + @("ps", "--format", "{{.Names}}")
$ListContainersCommand = Join-BashCommand -Parts $ListContainersParts

$ContainerNames = & ssh @SshArgs $ListContainersCommand 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Failed to list Docker containers. SSH or Docker command failed:`n$ContainerNames"
}

$ContainerNames | Set-Content -Path $ContainerListFile -Encoding UTF8

Write-Host "Containers found:"
$ContainerNames | ForEach-Object { Write-Host " - $_" }

if ($ContainerNames -notcontains $ContainerName) {
    throw "Container '$ContainerName' was not found. Container list saved to: $ContainerListFile"
}

Write-Step "Executing SQL inside container '$ContainerName'"

$PsqlParts = $DockerPartsPrefix + @(
    "exec",
    "-i"
)

if ($DbPassword -ne "") {
    $PsqlParts += "-e"
    $PsqlParts += "PGPASSWORD=$DbPassword"
}

$PsqlParts += @(
    $ContainerName,
    "psql",
    "-X",
    "-U", $DbUser,
    "-d", $DbName,
    "-v", "ON_ERROR_STOP=1",
    "-f", "-"
)

if ($OutputFormat -eq "csv") {
    $PsqlParts += "--csv"
}
elseif ($OutputFormat -eq "unaligned") {
    $PsqlParts += "-A"
    $PsqlParts += "-F"
    $PsqlParts += "`t"
}

$RemotePsqlCommand = Join-BashCommand -Parts $PsqlParts

Get-Content -Raw -Path $InputSqlFile | & ssh @SshArgs $RemotePsqlCommand 1> $ResultFile 2> $StdErrFile
$ExitCode = $LASTEXITCODE

$Status = if ($ExitCode -eq 0) { "OK" } else { "FAILED" }

$Summary = @(
    "Custom PostgreSQL SQL run",
    "Status: $Status",
    "Exit code: $ExitCode",
    "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "SSH target: $SshTarget",
    "Container: $ContainerName",
    "Database: $DbName",
    "User: $DbUser",
    "Output format: $OutputFormat",
    "",
    "Files:",
    "SQL:        $InputSqlFile",
    "Result:     $ResultFile",
    "STDERR:     $StdErrFile",
    "Containers: $ContainerListFile",
    "Summary:    $SummaryFile"
)

$Summary | Set-Content -Path $SummaryFile -Encoding UTF8

Write-Host ""
Write-Host "Done."
Write-Host "Status: $Status"
Write-Host ""
Write-Host "Results folder:"
Write-Host $RunDir
Write-Host ""
Write-Host "SQL:"
Write-Host $InputSqlFile
Write-Host ""
Write-Host "Result:"
Write-Host $ResultFile
Write-Host ""
Write-Host "STDERR:"
Write-Host $StdErrFile
Write-Host ""
Write-Host "Summary:"
Write-Host $SummaryFile
Write-Host ""

if ($ExitCode -ne 0) {
    Write-Host "SQL execution failed. Check stderr.txt for the error." -ForegroundColor Yellow
    exit $ExitCode
}

Write-Host "Open result:"
Write-Host "notepad `"$ResultFile`""
Write-Host ""
Write-Host "Open folder:"
Write-Host "explorer `"$RunDir`""
