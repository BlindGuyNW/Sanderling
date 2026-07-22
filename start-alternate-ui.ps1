<#
.SYNOPSIS
Deploy and run the alternate UI, reporting in plain text when it is actually ready to use.

.DESCRIPTION
Wraps `pine run-server`. Compared to implement/alternate-ui/run-alternate-ui.ps1 this script:

  - works from any directory (paths resolve relative to the script itself)
  - stops an instance already listening on the port instead of colliding with it
  - waits for the server to answer HTTP and prints a clear READY line, because the
    deploy compiles the Elm backend and can sit silent for a minute or more
  - surfaces the pine log if startup fails, rather than leaving you guessing

.PARAMETER Port
Port to serve the UI on. Default 80.

.PARAMETER Stop
Stop whatever is serving on the port and exit without starting anything.

.PARAMETER TimeoutSeconds
How long to wait for the server to come up before giving up. Default 300.

.EXAMPLE
./start-alternate-ui.ps1
.EXAMPLE
./start-alternate-ui.ps1 -Port 8080
.EXAMPLE
./start-alternate-ui.ps1 -Stop
#>
[CmdletBinding()]
param(
    [int]$Port = 80,
    [switch]$Stop,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot 'implement/alternate-ui/source'
$logPath = Join-Path $env:TEMP "sanderling-alternate-ui-$Port.log"
$url = "http://localhost:$Port/"

<#
Give each port its own process store. Without this, pine falls back to one shared default
store, so a second instance on another port collides with the first instead of running
alongside it - which defeats the point of -Port for trying a change without disturbing a
working instance. The store only holds deployment state and we redeploy from source every
time, so there is nothing here worth preserving between runs.
#>
$storePath = Join-Path $env:LOCALAPPDATA "Sanderling/alternate-ui-store-$Port"

function Get-ListenerProcess {
    param([int]$OnPort)
    $conn = Get-NetTCPConnection -State Listen -LocalPort $OnPort -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) { return $null }
    return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
}

function Stop-Existing {
    param([int]$OnPort)
    $proc = Get-ListenerProcess -OnPort $OnPort
    if (-not $proc) {
        Write-Host "Nothing is listening on port $OnPort."
        return
    }
    Write-Host "Stopping $($proc.ProcessName) (pid $($proc.Id)) on port $OnPort..."
    Stop-Process -Id $proc.Id -Force
    #  Give the socket a moment to be released so an immediate restart can bind it.
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Get-ListenerProcess -OnPort $OnPort)) { break }
    }
    Write-Host "Stopped."
}

if ($Stop) {
    Stop-Existing -OnPort $Port
    return
}

if (-not (Get-Command pine -ErrorAction SilentlyContinue)) {
    Write-Error "'pine' is not on PATH. Download it from https://github.com/pine-vm/pine/releases (needs the .NET runtime)."
    return
}

if (-not (Test-Path $sourcePath)) {
    Write-Error "Cannot find the app source at $sourcePath"
    return
}

Stop-Existing -OnPort $Port

Write-Host ""
Write-Host "Deploying from $sourcePath"
Write-Host "Log: $logPath"
Write-Host "Compiling - this normally takes one to two minutes."
Write-Host ""

if (Test-Path $logPath) { Remove-Item $logPath -Force }

$pineProcess = Start-Process -FilePath 'pine' `
    -ArgumentList @(
        'run-server',
        "--process-store=$storePath",
        "--admin-urls=http://*:$($Port + 20000)",
        "--public-urls=http://*:$Port",
        #  A store with no previous deployment refuses a plain --deploy ("No app config before").
        '--delete-previous-process',
        "--deploy=$sourcePath"
    ) `
    -PassThru -NoNewWindow `
    -RedirectStandardOutput $logPath `
    -RedirectStandardError "$logPath.err"

$started = Get-Date
$ready = $false
$lastReport = 0

while (((Get-Date) - $started).TotalSeconds -lt $TimeoutSeconds) {
    if ($pineProcess.HasExited) {
        Write-Host ""
        Write-Error "pine exited with code $($pineProcess.ExitCode) before the server came up. Log follows:"
        if (Test-Path $logPath) { Get-Content $logPath -Tail 30 }
        if (Test-Path "$logPath.err") { Get-Content "$logPath.err" -Tail 30 }
        return
    }

    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    }
    catch {
        #  Not up yet - expected while the Elm backend compiles.
    }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if (($elapsed - $lastReport) -ge 15) {
        Write-Host "  still starting... ${elapsed}s elapsed"
        $lastReport = $elapsed
    }

    Start-Sleep -Seconds 2
}

Write-Host ""
if ($ready) {
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Write-Host "READY after ${elapsed}s. The alternate UI is at $url"
    Write-Host "Inspector view: ${url}with-inspector"
    Write-Host "Stop it again with: ./start-alternate-ui.ps1 -Stop -Port $Port"
}
else {
    Write-Error "Timed out after ${TimeoutSeconds}s waiting for $url. pine is still running as pid $($pineProcess.Id); log at $logPath"
}
