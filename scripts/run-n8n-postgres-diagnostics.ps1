<#
.SYNOPSIS
Runs PostgreSQL diagnostic queries inside the n8n-postgres Docker container.

.DESCRIPTION
This script connects to an AWS Lightsail Ubuntu server over SSH, runs psql inside
the n8n-postgres Docker container, and saves each query result into your local
Windows log directory.

Each query is written to a local .sql file, executed remotely through:

docker exec -i n8n-postgres psql -U n8n -d auto_pws --csv -f -

Output files:
- One CSV file per query
- One STDERR file per query
- One SQL file per query
- One summary TXT file
- One container list TXT file

The script keeps running even if one query fails. This is useful because some
databases may not have pg_cron installed, so cron.job or cron.job_run_details
may not exist.

.BASIC USAGE
powershell -ExecutionPolicy Bypass -File .\run-n8n-postgres-diagnostics.ps1

.PARAMETER Key
Path to the SSH private key file.

Example:
-Key "X:\location\of\pem"

.PARAMETER SshUser
Remote Linux user.

Default:
ubuntu

.PARAMETER SshHost
Remote server hostname or IP.

Default:
auto.palmwavestays.com

.PARAMETER ContainerName
Docker container where PostgreSQL is running.

Default:
n8n-postgres

.PARAMETER DbUser
PostgreSQL user.

Default:
n8n

.PARAMETER DbName
PostgreSQL database name.

Default:
auto_pws

.PARAMETER DbPassword
Optional PostgreSQL password. Leave blank if psql works inside the container
without a password.

Example:
-DbPassword "your_password_here"

.PARAMETER OutDir
Local Windows folder where query results will be saved.

Default:
Z:\Projects\pws_auto\temp\data-overflow testing\docker-log

.PARAMETER UseSudo
Use sudo docker instead of docker on the remote server.

Example:
-UseSudo

.EXAMPLE
Run with defaults:

powershell -ExecutionPolicy Bypass -File .\run-n8n-postgres-diagnostics.ps1

.EXAMPLE
Run with your real key path:

powershell -ExecutionPolicy Bypass -File .\run-n8n-postgres-diagnostics.ps1 `
  -Key "X:\location\of\pem"

.EXAMPLE
Use sudo docker:

powershell -ExecutionPolicy Bypass -File .\run-n8n-postgres-diagnostics.ps1 `
  -UseSudo

.EXAMPLE
Save results to another folder:

powershell -ExecutionPolicy Bypass -File .\run-n8n-postgres-diagnostics.ps1 `
  -OutDir "Z:\Projects\pws_auto\temp\data-overflow testing\docker-log"

.EXAMPLE
Run against another container:

powershell -ExecutionPolicy Bypass -File .\run-n8n-postgres-diagnostics.ps1 `
  -ContainerName "n8n-postgres"

.NOTES
Before running, you can confirm the container manually:

ssh -i "X:\location\of\pem" ubuntu@auto.palmwavestays.com 'docker ps --format "{{.Names}}"'

Known containers from your server:
n8n-postgres
n8n-nginx
#>

[CmdletBinding()]
param (
    [string]$Key = "C:\Users\dprah\.ssh\aws-lightsail-mumbai.pem",

    [string]$SshUser = "ubuntu",

    [string]$SshHost = "auto.palmwavestays.com",

    [string]$ContainerName = "n8n-postgres",

    [string]$DbUser = "n8n",

    [string]$DbName = "auto_pws",

    [string]$DbPassword = "",

    [string]$OutDir = "Z:\Projects\pws_auto\temp\data-overflow testing\docker-log",

    [switch]$UseSudo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param (
        [string]$Message
    )

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
    param (
        [string[]]$Parts
    )

    return ($Parts | ForEach-Object { Quote-BashArg $_ }) -join " "
}

function New-QueryObject {
    param (
        [string]$Name,
        [string]$Description,
        [string]$Sql
    )

    [PSCustomObject]@{
        Name = $Name
        Description = $Description
        Sql = $Sql.Trim()
    }
}

if (-not (Test-Path $Key)) {
    throw "SSH key was not found: $Key"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$RunTag = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $OutDir "postgres_diagnostics_$RunTag"
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$SshTarget = "$SshUser@$SshHost"

$SshArgs = @(
    "-i", $Key,
    "-o", "StrictHostKeyChecking=accept-new",
    $SshTarget
)

$DockerBinary = if ($UseSudo) { "sudo docker" } else { "docker" }

$SummaryFile = Join-Path $RunDir "summary.txt"
$ContainerListFile = Join-Path $RunDir "docker_containers.txt"

$Queries = @(
    New-QueryObject `
        -Name "01_delete_cleanup_archive_functions" `
        -Description "Find all delete, cleanup, archive, and purge functions" `
        -Sql @'
SELECT 
    n.nspname AS schema_name,
    p.proname AS function_name,
    p.prosrc AS function_source
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname ILIKE '%delete%'
   OR p.proname ILIKE '%archive%'
   OR p.proname ILIKE '%cleanup%'
   OR p.proname ILIKE '%purge%'
ORDER BY n.nspname, p.proname;
'@

    New-QueryObject `
        -Name "02_pg_cron_scheduled_jobs" `
        -Description "Check pg_cron scheduled jobs" `
        -Sql @'
SELECT 
    jobid,
    schedule,
    command,
    nodename,
    database,
    username,
    active
FROM cron.job
ORDER BY jobid;
'@

    New-QueryObject `
        -Name "03_recent_cron_job_executions" `
        -Description "Check recent pg_cron job executions" `
        -Sql @'
SELECT 
    job_id,
    database,
    command,
    status,
    return_message,
    start_time,
    end_time,
    ROUND(EXTRACT(epoch FROM (end_time - start_time)), 2) AS duration_seconds
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 30;
'@

    New-QueryObject `
        -Name "04_task_table_triggers" `
        -Description "Find triggers on task_queue and task_metadata_history" `
        -Sql @'
SELECT 
    t.trigger_name,
    t.event_object_table,
    t.event_manipulation,
    t.action_statement
FROM information_schema.triggers t
WHERE t.event_object_table IN ('task_queue', 'task_metadata_history')
ORDER BY t.event_object_table, t.trigger_name;
'@

    New-QueryObject `
        -Name "05_delete_operations_in_functions" `
        -Description "Look for DELETE operations in functions" `
        -Sql @'
SELECT 
    n.nspname AS schema_name,
    p.proname AS function_name,
    p.prosrc AS source_code,
    pg_get_functiondef(p.oid) AS full_definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE LOWER(p.prosrc) LIKE '%delete%from%task%'
   OR LOWER(p.prosrc) LIKE '%delete%from%queue%'
ORDER BY n.nspname, p.proname;
'@

    New-QueryObject `
        -Name "06_scheduled_application_tasks" `
        -Description "Check scheduled tasks in task_queue" `
        -Sql @'
SELECT 
    task_name,
    COUNT(*) as total_count,
    COUNT(*) FILTER (WHERE status = 'scheduled') as scheduled_count,
    COUNT(*) FILTER (WHERE status = 'completed') as completed_count,
    COUNT(*) FILTER (WHERE status = 'failed') as failed_count,
    MIN(created_at) as earliest,
    MAX(created_at) as latest
FROM task_queue
WHERE recurrence_pattern IS NOT NULL
GROUP BY task_name
ORDER BY total_count DESC;
'@

    New-QueryObject `
        -Name "07_worker_spike_analysis" `
        -Description "Analyze which workers created tasks during the spike window" `
        -Sql @'
SELECT 
    worker_id,
    COUNT(*) as task_count,
    COUNT(*) FILTER (WHERE status = 'completed') as completed_count,
    MIN(created_at) as first_created,
    MAX(completed_at) as last_completed
FROM task_queue
WHERE created_at >= '2026-05-16 06:00:00+06'
  AND created_at <= '2026-05-16 21:30:00+06'
GROUP BY worker_id
ORDER BY task_count DESC;
'@

    New-QueryObject `
        -Name "08_task_metadata_history_window" `
        -Description "Check task metadata history around the spike start" `
        -Sql @'
SELECT 
    *
FROM task_metadata_history
WHERE created_at >= '2026-05-16 05:50:00+06'
  AND created_at <= '2026-05-16 06:10:00+06'
ORDER BY created_at
LIMIT 20;
'@
)

Write-Step "Checking Docker containers on remote server"

$ListContainersCommand = "$DockerBinary ps --format '{{.Names}}'"
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

$SummaryLines = New-Object System.Collections.Generic.List[string]
$SummaryLines.Add("PostgreSQL diagnostic query run")
$SummaryLines.Add("Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$SummaryLines.Add("SSH target: $SshTarget")
$SummaryLines.Add("Container: $ContainerName")
$SummaryLines.Add("Database: $DbName")
$SummaryLines.Add("User: $DbUser")
$SummaryLines.Add("Output folder: $RunDir")
$SummaryLines.Add("")
$SummaryLines.Add("Query results:")

foreach ($Query in $Queries) {
    Write-Step "Running $($Query.Name): $($Query.Description)"

    $SqlFile = Join-Path $RunDir "$($Query.Name).sql"
    $CsvFile = Join-Path $RunDir "$($Query.Name).csv"
    $ErrFile = Join-Path $RunDir "$($Query.Name).stderr.txt"

    $Query.Sql | Set-Content -Path $SqlFile -Encoding UTF8

    $DockerParts = @()

    if ($UseSudo) {
        $DockerParts += "sudo"
    }

    $DockerParts += "docker"
    $DockerParts += "exec"
    $DockerParts += "-i"

    if ($DbPassword -ne "") {
        $DockerParts += "-e"
        $DockerParts += "PGPASSWORD=$DbPassword"
    }

    $DockerParts += $ContainerName
    $DockerParts += "psql"
    $DockerParts += "-X"
    $DockerParts += "-U"
    $DockerParts += $DbUser
    $DockerParts += "-d"
    $DockerParts += $DbName
    $DockerParts += "--csv"
    $DockerParts += "-v"
    $DockerParts += "ON_ERROR_STOP=1"
    $DockerParts += "-f"
    $DockerParts += "-"

    $RemotePsqlCommand = Join-BashCommand -Parts $DockerParts

    Get-Content -Raw -Path $SqlFile | & ssh @SshArgs $RemotePsqlCommand 1> $CsvFile 2> $ErrFile
    $ExitCode = $LASTEXITCODE

    $Status = if ($ExitCode -eq 0) { "OK" } else { "FAILED" }

    $SummaryLines.Add("[$Status] $($Query.Name)")
    $SummaryLines.Add("  Description: $($Query.Description)")
    $SummaryLines.Add("  SQL:    $SqlFile")
    $SummaryLines.Add("  CSV:    $CsvFile")
    $SummaryLines.Add("  STDERR: $ErrFile")
    $SummaryLines.Add("  Exit:   $ExitCode")
    $SummaryLines.Add("")

    if ($ExitCode -eq 0) {
        Write-Host "Saved CSV: $CsvFile"
    } else {
        Write-Host "Query failed. Check STDERR: $ErrFile" -ForegroundColor Yellow
    }
}

$SummaryLines | Set-Content -Path $SummaryFile -Encoding UTF8

Write-Host ""
Write-Host "Done."
Write-Host ""
Write-Host "Results folder:"
Write-Host $RunDir
Write-Host ""
Write-Host "Summary:"
Write-Host $SummaryFile
Write-Host ""
Write-Host "Open results folder:"
Write-Host "explorer `"$RunDir`""
