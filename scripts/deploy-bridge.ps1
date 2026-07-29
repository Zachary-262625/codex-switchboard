[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$CcSwitchExe,
    [string]$CodexAumid,
    [ValidateRange(1024, 65535)]
    [int]$Port = 17823
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$InstallDir = Get-SwitchboardInstallDir $InstallDir
$CcSwitchExe = Find-CcSwitchExecutable $CcSwitchExe
$CodexAumid = Find-CodexAumid $CodexAumid
$node = Get-Command node.exe -ErrorAction SilentlyContinue

if (-not $node) {
    throw 'Node.js was not found. Run install-prerequisites.ps1 -Install first.'
}
if (-not $CcSwitchExe) {
    throw 'CC Switch was not found. Pass -CcSwitchExe with the full portable or installed path.'
}
if (-not $CodexAumid) {
    throw 'Codex Desktop AppUserModelId was not found. Install Codex Desktop or pass -CodexAumid.'
}

$assetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\bridge'
$sourceServer = Join-Path $assetDir 'server.mjs'
$sourceLauncher = Join-Path $assetDir 'start-bridge.ps1'
if (-not (Test-Path -LiteralPath $sourceServer) -or -not (Test-Path -LiteralPath $sourceLauncher)) {
    throw "Bundled Bridge assets are incomplete: $assetDir"
}

$runtimeDir = Join-Path $InstallDir 'runtime'
$configPath = Join-Path $runtimeDir 'config.json'
$pidPath = Join-Path $runtimeDir 'bridge.pid'
$handoffPath = Join-Path $InstallDir 'HANDOFF.md'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
if (Test-Path -LiteralPath $pidPath) {
    $bridgePidText = (Get-Content -LiteralPath $pidPath -Raw).Trim()
    if ($bridgePidText -match '^\d+$') {
        $bridgeProcess = Get-Process -Id ([int]$bridgePidText) -ErrorAction SilentlyContinue
        if ($bridgeProcess -and $bridgeProcess.ProcessName -eq 'node') {
            Stop-Process -Id $bridgeProcess.Id -Force
            $bridgeProcess.WaitForExit(5000)
        }
    }
}

Copy-Item -LiteralPath $sourceServer -Destination (Join-Path $InstallDir 'server.mjs') -Force
Copy-Item -LiteralPath $sourceLauncher -Destination (Join-Path $InstallDir 'start-bridge.ps1') -Force

$config = [ordered]@{}
if (Test-Path -LiteralPath $configPath) {
    try {
        $existing = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $existing.PSObject.Properties) {
            $config[$property.Name] = $property.Value
        }
    } catch {
        throw "Existing Bridge config is invalid: $($_.Exception.Message)"
    }
}
$config.host = '127.0.0.1'
$config.port = $Port
$config.ccSwitchExe = $CcSwitchExe
$config.webViewDataDir = Join-Path $env:LOCALAPPDATA 'com.ccswitch.desktop\EBWebView'
$config.codexConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$config.codexAumid = $CodexAumid
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8

if (-not (Test-Path -LiteralPath $handoffPath)) {
    @(
        '# Codex Switchboard handoff'
        ''
        'This file is append-only operational context for model switches.'
    ) | Set-Content -LiteralPath $handoffPath -Encoding UTF8
}

$oldCcSwitchRun = (Get-ItemProperty -LiteralPath $runKey -Name 'CC Switch' -ErrorAction SilentlyContinue).'CC Switch'
$statePath = Join-Path $runtimeDir 'install-state.json'
$state = [ordered]@{
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    installDir = $InstallDir
    previousCcSwitchRun = $oldCcSwitchRun
}
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
Remove-ItemProperty -LiteralPath $runKey -Name 'CC Switch' -ErrorAction SilentlyContinue

$launcher = Join-Path $InstallDir 'start-bridge.ps1'
$command = "`"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
Set-ItemProperty -LiteralPath $runKey -Name 'Codex Switchboard Bridge' -Value $command

& $launcher
Start-SwitchboardBridge $InstallDir

[ordered]@{
    ok = $true
    installDir = $InstallDir
    localUrl = "http://127.0.0.1:$Port/"
    passwordFile = Join-Path $runtimeDir 'first-login.txt'
    next = 'Run get-status.ps1, then enable-phone-access.ps1.'
} | ConvertTo-Json -Depth 4
