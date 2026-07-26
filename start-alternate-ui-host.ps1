<#
.SYNOPSIS
Build and run the .NET host for the alternate UI (the Pine-backend replacement).

.DESCRIPTION
Counterpart to start-alternate-ui.ps1 for the new host in implement/alternate-ui-host/
(see implement/alternate-ui/PLAN-dotnet-host.md). It:

  - compiles the Elm frontend to HTML with `pine make` (pine stays a build tool here;
    nothing of Pine runs at serve time) - both the normal and the --debug variant
  - builds the host with `dotnet build` and starts it hidden, logging to a file
  - stops an instance already listening on the port instead of colliding with it
  - waits until the server answers HTTP and prints a clear READY line

Until plan phase 4, this host runs on 8080 by default while the pine instance keeps 80.

.PARAMETER Port
Port to serve on. Default 8080.

.PARAMETER Stop
Stop whatever is serving on the port and exit without starting anything.

.PARAMETER SkipFrontendBuild
Reuse the previously built frontend HTML instead of running `pine make` again. Saves about
a minute when only the C# host changed.

.EXAMPLE
./start-alternate-ui-host.ps1
.EXAMPLE
./start-alternate-ui-host.ps1 -SkipFrontendBuild
.EXAMPLE
./start-alternate-ui-host.ps1 -Stop
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$Stop,
    [switch]$SkipFrontendBuild,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

$hostProjectPath = Join-Path $PSScriptRoot 'implement/alternate-ui-host'
$frontendSourcePath = Join-Path $PSScriptRoot 'implement/alternate-ui/source'
$wwwrootPath = Join-Path $hostProjectPath 'wwwroot'
$logPath = Join-Path $env:TEMP "sanderling-alternate-ui-host-$Port.log"
$url = "http://localhost:$Port/"

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

$frontendHtml = Join-Path $wwwrootPath 'alternate-ui.html'
$frontendDebugHtml = Join-Path $wwwrootPath 'alternate-ui-debug.html'

if ($SkipFrontendBuild -and -not (Test-Path $frontendHtml)) {
    Write-Host "No previously built frontend at $frontendHtml - building it after all."
    $SkipFrontendBuild = $false
}

if (-not $SkipFrontendBuild) {
    if (-not (Get-Command pine -ErrorAction SilentlyContinue)) {
        Write-Error "'pine' is not on PATH; it is needed to compile the Elm frontend. Download it from https://github.com/pine-vm/pine/releases"
        return
    }

    New-Item -ItemType Directory -Force $wwwrootPath | Out-Null

    Write-Host "Compiling the Elm frontend (pine make, normal + debug) - takes about a minute..."
    Push-Location $frontendSourcePath
    try {
        pine make src/Frontend/Main.elm --output=$frontendHtml
        if ($LASTEXITCODE -ne 0) { throw "pine make failed with exit code $LASTEXITCODE" }
        pine make src/Frontend/Main.elm --debug --output=$frontendDebugHtml
        if ($LASTEXITCODE -ne 0) { throw "pine make --debug failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

#  Stop before building: a running instance holds a lock on the exe the build overwrites.
Stop-Existing -OnPort $Port

Write-Host "Building the host..."
dotnet build (Join-Path $hostProjectPath 'alternate-ui-host.csproj') -c Release --nologo -v quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "dotnet build failed with exit code $LASTEXITCODE"
    return
}

$hostExe = Join-Path $hostProjectPath 'bin/Release/net9.0-windows/alternate-ui-host.exe'
if (-not (Test-Path $hostExe)) {
    Write-Error "Built host not found at $hostExe"
    return
}

if (Test-Path $logPath) { Remove-Item $logPath -Force }

#  -WindowStyle Hidden, NOT -NoNewWindow, for the same reason as in start-alternate-ui.ps1:
#  a process attached to this console would keep a dead window open after `exit`.
$hostProcess = Start-Process -FilePath $hostExe `
    -ArgumentList @("--urls=http://localhost:$Port") `
    -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $logPath `
    -RedirectStandardError "$logPath.err"

$started = Get-Date
$ready = $false

while (((Get-Date) - $started).TotalSeconds -lt $TimeoutSeconds) {
    if ($hostProcess.HasExited) {
        Write-Host ""
        Write-Error "Host exited with code $($hostProcess.ExitCode) before the server came up. Log follows:"
        if (Test-Path $logPath) { Get-Content $logPath -Tail 30 }
        if (Test-Path "$logPath.err") { Get-Content "$logPath.err" -Tail 30 }
        return
    }

    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    }
    catch {
        #  Not up yet.
    }

    Start-Sleep -Milliseconds 500
}

Write-Host ""
if ($ready) {
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Write-Host "READY after ${elapsed}s. The alternate UI (dotnet host) is at $url"
    Write-Host "Inspector view: ${url}with-inspector"
    Write-Host "Log: $logPath"
    Write-Host "Stop it again with: ./start-alternate-ui-host.ps1 -Stop -Port $Port"
}
else {
    Write-Error "Timed out after ${TimeoutSeconds}s waiting for $url. Host is still running as pid $($hostProcess.Id); log at $logPath"
}
