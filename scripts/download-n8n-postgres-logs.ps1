<#
.SYNOPSIS
Downloads Docker logs from an AWS Lightsail server over SSH.

.DESCRIPTION
This script connects to a remote Ubuntu server using SSH, checks that the Docker
container exists, downloads logs for a selected time range, and creates a filtered
log file locally.

By default, it downloads logs from the n8n-postgres container and filters lines
matching:

batch, import, bulk, job, schedule

The script is designed to run from Windows PowerShell.

.BASIC USAGE
powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1

.PARAMETER Key
Path to the SSH private key file.

Example:
-Key "X:\location\of\pem"

.PARAMETER SshUser
Remote Linux username.

Default:
ubuntu

.PARAMETER SshHost
Remote server hostname or IP.

Default:
auto.palmwavestays.com

.PARAMETER ContainerName
Docker container name to download logs from.

Default:
n8n-postgres

Examples:
-ContainerName "n8n-postgres"
-ContainerName "n8n-nginx"

.PARAMETER Since
Start datetime for Docker logs.

Use ISO format with timezone.

Example:
-Since "2026-05-15T23:00:00+06:00"

.PARAMETER Until
End datetime for Docker logs.

Use ISO format with timezone.

Example:
-Until "2026-05-16T22:00:00+06:00"

.PARAMETER OutDir
Local Windows folder where logs will be saved.

Example:
-OutDir "Z:\Projects\pws_auto\temp\data-overflow testing\docker-log"

.PARAMETER FilterRegex
Regex used to create the filtered log file.

Default:
batch|import|bulk|job|schedule

Examples:
-FilterRegex "error|failed|timeout"
-FilterRegex "batch|import|bulk|job|schedule"
-FilterRegex "postgres|checkpoint|database"

.PARAMETER UseSudo
Use sudo docker instead of docker on the remote server.

Example:
-UseSudo

.EXAMPLE
Download default n8n-postgres logs using the default time range:

powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1

.EXAMPLE
Download nginx logs instead of postgres:

powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1 `
  -ContainerName "n8n-nginx"

.EXAMPLE
Download logs for a different time range:

powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1 `
  -Since "2026-05-16T00:00:00+06:00" `
  -Until "2026-05-16T23:59:59+06:00"

.EXAMPLE
Filter only errors and failures:

powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1 `
  -FilterRegex "error|failed|failure|timeout"

.EXAMPLE
Use sudo docker on the server:

powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1 `
  -UseSudo

.EXAMPLE
Use a different output folder:

powershell -ExecutionPolicy Bypass -File .\download-n8n-postgres-logs.ps1 `
  -OutDir "Z:\Projects\pws_auto\logs"

.NOTES
Before running, confirm the container name:

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

    [string]$Since = "2026-05-15T23:00:00+06:00",

    [string]$Until = "2026-05-16T22:00:00+06:00",

    [string]$OutDir = "Z:\Projects\pws_auto\temp\data-overflow testing\docker-log",

    [string]$FilterRegex = "batch|import|bulk|job|schedule",

    [switch]$UseSudo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Validate local SSH key
# -----------------------------

if (-not (Test-Path $Key)) {
    throw "SSH key was not found: $Key"
}

# -----------------------------
# Internal setup
# -----------------------------

$SshTarget = "$SshUser@$SshHost"
$DockerCmd = if ($UseSudo) { "sudo docker" } else { "docker" }

$SafeSince = $Since -replace "[:+]", "-"
$SafeUntil = $Until -replace "[:+]", "-"
$TimeTag = "${SafeSince}_to_${SafeUntil}"

$FullLogFile = Join-Path $OutDir "$ContainerName`_$TimeTag`_full.log"
$FilteredLogFile = Join-Path $OutDir "$ContainerName`_$TimeTag`_filtered.log"
$ContainerListFile = Join-Path $OutDir "docker_containers.txt"

$SshArgs = @(
    "-i", $Key,
    "-o", "StrictHostKeyChecking=accept-new",
    $SshTarget
)

# -----------------------------
# Create output folder
# -----------------------------

Write-Host ""
Write-Host "Creating output folder..."
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# -----------------------------
# Check Docker containers
# -----------------------------

Write-Host ""
Write-Host "Checking Docker containers on remote server..."

$ListContainersCommand = "$DockerCmd ps --format '{{.Names}}'"

$ContainerNames = & ssh @SshArgs $ListContainersCommand 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Failed to list Docker containers. SSH or Docker command failed:`n$ContainerNames"
}

$ContainerNames | Set-Content -Path $ContainerListFile -Encoding UTF8

Write-Host ""
Write-Host "Containers found:"
$ContainerNames | ForEach-Object { Write-Host " - $_" }

if ($ContainerNames -notcontains $ContainerName) {
    throw "Container '$ContainerName' was not found. See container list: $ContainerListFile"
}

# -----------------------------
# Download full Docker logs
# -----------------------------

Write-Host ""
Write-Host "Downloading full logs..."
Write-Host "Container: $ContainerName"
Write-Host "Since:     $Since"
Write-Host "Until:     $Until"

$RemoteLogCommand = "$DockerCmd logs $ContainerName --since '$Since' --until '$Until' 2>&1"

& ssh @SshArgs $RemoteLogCommand 2>&1 |
    Set-Content -Path $FullLogFile -Encoding UTF8

if ($LASTEXITCODE -ne 0) {
    throw "Failed to download Docker logs from '$ContainerName'."
}

Write-Host ""
Write-Host "Full log saved:"
Write-Host $FullLogFile

# -----------------------------
# Create filtered log locally
# -----------------------------

Write-Host ""
Write-Host "Creating filtered log..."
Write-Host "Filter regex: $FilterRegex"

$Matches = Select-String -Path $FullLogFile -Pattern $FilterRegex -AllMatches

if ($Matches) {
    $Matches |
        ForEach-Object { $_.Line } |
        Set-Content -Path $FilteredLogFile -Encoding UTF8
} else {
    "" | Set-Content -Path $FilteredLogFile -Encoding UTF8
}

Write-Host ""
Write-Host "Filtered log saved:"
Write-Host $FilteredLogFile

# -----------------------------
# Summary
# -----------------------------

Write-Host ""
Write-Host "Done."
Write-Host ""
Write-Host "Output files:"
Write-Host "Containers: $ContainerListFile"
Write-Host "Full log:   $FullLogFile"
Write-Host "Filtered:   $FilteredLogFile"

Write-Host ""
Write-Host "Open filtered log with:"
Write-Host "notepad `"$FilteredLogFile`""