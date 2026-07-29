$ErrorActionPreference = 'Stop'
$bridgeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
$node = if ($nodeCommand) { $nodeCommand.Source } else { 'C:\Program Files\nodejs\node.exe' }
if (-not (Test-Path -LiteralPath $node)) {
    throw 'Node.js was not found.'
}

$server = Join-Path $bridgeDir 'server.mjs'
$pidFile = Join-Path $bridgeDir 'runtime\bridge.pid'
$alreadyRunning = $false
if (Test-Path -LiteralPath $pidFile) {
    $bridgePidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($bridgePidText -match '^\d+$') {
        $process = Get-Process -Id ([int]$bridgePidText) -ErrorAction SilentlyContinue
        $alreadyRunning = [bool]($process -and $process.ProcessName -eq 'node')
    }
}
if (-not $alreadyRunning) {
    Start-Process `
        -FilePath $node `
        -ArgumentList @("`"$server`"") `
        -WorkingDirectory $bridgeDir `
        -WindowStyle Hidden
}
