<#
.SYNOPSIS
Starts a worker debug session inside the Docker `workers` container.

.DESCRIPTION
Reads `.env.local` by default, resolves the worker selected by
`WORKER_DEBUG_WORKER`, starts or refreshes the `workers` service, and then
launches the reserved worker under `debugpy` inside the container.

The script uses the manifest at `workers/pws_workers/worker_manifest.json` to
resolve the target script path and standard worker arguments.

.PARAMETER WorkerName
Optional worker name override. When omitted, uses `WORKER_DEBUG_WORKER` from
the env file.

.PARAMETER EnvFile
Env file to use for docker compose. Defaults to `.env.local`.

.PARAMETER NoBuild
Skips `--build` when starting the `workers` service.

.PARAMETER DryRun
Prints the commands without running them.

.EXAMPLE
pwsh -NoProfile -File scripts/start-worker-debug.ps1

.EXAMPLE
pwsh -NoProfile -File scripts/start-worker-debug.ps1 -WorkerName messages-worker

.EXAMPLE
pwsh -NoProfile -File scripts/start-worker-debug.ps1 -WorkerName messages-worker -HeartbeatInterval "5 seconds" -LeaseDuration "30 seconds"

.EXAMPLE
pwsh -NoProfile -File scripts/start-worker-debug.ps1 -WorkerName external-services-worker -HeartbeatInterval "10 seconds" -LeaseDuration "1 minute"
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$WorkerName,
    [string]$HeartbeatInterval,
    [string]$LeaseDuration,
    [string]$EnvFile = '.env.local',
    [switch]$NoBuild,
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Resolve-ExecutablePath {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $resolved = Get-Command -Name $CommandName -ErrorAction Stop | Select-Object -First 1
    return $resolved.Source
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Env file not found: $Path"
    }

    $values = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            continue
        }

        $parts = $line.Split('=', 2)
        $key = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        $values[$key] = $value
    }

    return $values
}

function Resolve-SelectedWorkerName {
    param(
        [AllowNull()][string]$RequestedWorkerName,
        [Parameter(Mandatory = $true)][hashtable]$EnvValues
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedWorkerName)) {
        return $RequestedWorkerName.Trim()
    }

    $fromEnv = [string]$EnvValues['WORKER_DEBUG_WORKER']
    if ([string]::IsNullOrWhiteSpace($fromEnv)) {
        throw "WORKER_DEBUG_WORKER is not set in the env file. Set it in '$EnvFile' or pass -WorkerName."
    }

    return $fromEnv.Trim()
}

function Resolve-HostDebugPort {
    param([Parameter(Mandatory = $true)][hashtable]$EnvValues)

    $portText = [string]$EnvValues['WORKERS_DEBUG_PORT']
    if ([string]::IsNullOrWhiteSpace($portText)) {
        return 5678
    }

    $parsedPort = 0
    if (-not [int]::TryParse($portText, [ref]$parsedPort)) {
        throw "WORKERS_DEBUG_PORT must be an integer in the env file."
    }

    return $parsedPort
}

function Resolve-TargetDbName {
    param([Parameter(Mandatory = $true)][hashtable]$EnvValues)

    foreach ($name in @('WORKER_DB_NAME', 'SCHEMA_DB', 'POSTGRES_DB')) {
        $value = [string]$EnvValues[$name]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return 'auto_pws'
}

function Get-WorkerManifestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$TargetWorkerName
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $entry = @($manifest.workers | Where-Object { $_.name -eq $TargetWorkerName } | Select-Object -First 1)
    if ($entry.Count -eq 0) {
        $available = @($manifest.workers | ForEach-Object { $_.name }) -join ', '
        throw "Unknown worker '$TargetWorkerName'. Available workers: $available"
    }

    return $entry[0]
}

function Resolve-WorkerLaunchArgs {
    param(
        [Parameter(Mandatory = $true)]$ManifestEntry,
        [Parameter(Mandatory = $true)][string]$DbName,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [AllowNull()][string]$HeartbeatIntervalOverride,
        [AllowNull()][string]$LeaseDurationOverride
    )

    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @($ManifestEntry.args)) {
        switch ([string]$arg) {
            '{db}' { $resolved.Add($DbName) }
            '{logdir}' { $resolved.Add($LogDir) }
            default { $resolved.Add([string]$arg) }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($HeartbeatIntervalOverride)) {
        $resolved.Add('--heartbeat-interval')
        $resolved.Add($HeartbeatIntervalOverride.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($LeaseDurationOverride)) {
        $resolved.Add('--lease-duration')
        $resolved.Add($LeaseDurationOverride.Trim())
    }

    return @($resolved)
}

function Test-DebugpyPortAvailability {
    param(
        [Parameter(Mandatory = $true)][string]$DockerPath,
        [Parameter(Mandatory = $true)][string[]]$ComposeArgs,
        [int]$ContainerPort = 5678,
        [switch]$DryRunMode
    )

    if ($DryRunMode) {
        return
    }

    $probeScript = @"
import os
import socket
import sys

port = $ContainerPort
current_pid = str(os.getpid())
s = socket.socket()
try:
    s.bind(("0.0.0.0", port))
except OSError:
    print(f"DEBUGPY_PORT_IN_USE:{port}")
    for pid in sorted(p for p in os.listdir("/proc") if p.isdigit()):
        if pid == current_pid:
            continue
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\x00", b" ").decode("utf-8", "ignore").strip()
        except Exception:
            continue
        if "debugpy" in cmd:
            print(f"PID={pid} CMD={cmd}")
    sys.exit(1)
else:
    print(f"DEBUGPY_PORT_AVAILABLE:{port}")
finally:
    s.close()
"@

    $probeArgs = @($ComposeArgs) + @(
        'exec',
        '-T',
        'workers',
        'python',
        '-c',
        $probeScript
    )
    $probeOutput = & $DockerPath @probeArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        return
    }

    $details = @($probeOutput | Where-Object { $_ -match '^PID=' })
    $message = @(
        "Debug port $ContainerPort is already in use inside the 'workers' container."
        'A previous debugpy session is still listening, so the new attach session cannot start.'
        'Stop the old debug session, restart the workers container, or terminate the stale debugpy process and try again.'
    )
    if ($details.Count -gt 0) {
        $message += 'Existing debugpy processes:'
        $message += $details
    }

    throw ($message -join [Environment]::NewLine)
}

function Invoke-StreamingExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [switch]$DryRunMode
    )

    $display = @($FilePath) + $ArgumentList
    Write-Host ($display -join ' ')

    if ($DryRunMode) {
        return
    }

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE"
    }
}

$scriptRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$repoRoot = Resolve-FullPath -BasePath $scriptRoot -Path '..'
$resolvedEnvFile = Resolve-FullPath -BasePath $repoRoot -Path $EnvFile
$manifestPath = Resolve-FullPath -BasePath $repoRoot -Path 'workers\pws_workers\worker_manifest.json'
$dockerPath = Resolve-ExecutablePath -CommandName 'docker'
$envValues = Read-DotEnv -Path $resolvedEnvFile
$selectedWorker = Resolve-SelectedWorkerName -RequestedWorkerName $WorkerName -EnvValues $envValues
$hostDebugPort = Resolve-HostDebugPort -EnvValues $envValues
$targetDb = Resolve-TargetDbName -EnvValues $envValues
$workerEntry = Get-WorkerManifestEntry -ManifestPath $manifestPath -TargetWorkerName $selectedWorker
$workerArgs = Resolve-WorkerLaunchArgs `
    -ManifestEntry $workerEntry `
    -DbName $targetDb `
    -LogDir 'output/worker-logs' `
    -HeartbeatIntervalOverride $HeartbeatInterval `
    -LeaseDurationOverride $LeaseDuration
$containerScriptPath = ('workers/pws_workers/' + ([string]$workerEntry.script_path).Replace('\', '/'))
$composeBaseArgs = @(
    'compose',
    '-f',
    'docker-compose.yml',
    '-f',
    'docker-compose.local.yml',
    '--env-file',
    $resolvedEnvFile
)

if ([string]$envValues['WORKER_DEBUG_WORKER'] -ne $selectedWorker) {
    $env:WORKER_DEBUG_WORKER = $selectedWorker
}

Push-Location $repoRoot
try {
    Write-Section -Title 'Worker Debug Target'
    Write-Host "Worker: $selectedWorker"
    Write-Host "Script: $containerScriptPath"
    Write-Host "Database: $targetDb"
    Write-Host "VS Code attach port: $hostDebugPort"
    if (-not [string]::IsNullOrWhiteSpace($HeartbeatInterval)) {
        Write-Host "Heartbeat interval override: $HeartbeatInterval"
    }
    if (-not [string]::IsNullOrWhiteSpace($LeaseDuration)) {
        Write-Host "Lease duration override: $LeaseDuration"
    }

    Write-Section -Title 'Starting Workers Service'
    $composeUpArgs = @($composeBaseArgs) + @('up', '-d')
    if (-not $NoBuild) {
        $composeUpArgs += '--build'
    }
    $composeUpArgs += 'workers'
    Invoke-StreamingExternalCommand -FilePath $dockerPath -ArgumentList $composeUpArgs -DryRunMode:$DryRun

    Write-Section -Title 'Checking Debug Port'
    Test-DebugpyPortAvailability -DockerPath $dockerPath -ComposeArgs $composeBaseArgs -DryRunMode:$DryRun

    Write-Section -Title 'Starting Debugpy Session'
    Write-Host "Attach in VS Code using 'Python: Attach to Workers Container'."
    Write-Host "When prompted for the port, enter $hostDebugPort."
    $composeExecArgs = @($composeBaseArgs) + @(
        'exec',
        'workers',
        'python',
        '-Xfrozen_modules=off',
        '-m',
        'debugpy',
        '--listen',
        '0.0.0.0:5678',
        '--wait-for-client',
        $containerScriptPath
    ) + $workerArgs
    Invoke-StreamingExternalCommand -FilePath $dockerPath -ArgumentList $composeExecArgs -DryRunMode:$DryRun
}
finally {
    Pop-Location
    Remove-Item Env:WORKER_DEBUG_WORKER -ErrorAction SilentlyContinue
}
