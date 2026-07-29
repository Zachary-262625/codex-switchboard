[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$InstallDir = Get-SwitchboardInstallDir $InstallDir
$runtimeDir = Join-Path $InstallDir 'runtime'
$statePath = Join-Path $runtimeDir 'install-state.json'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

if (Test-Path -LiteralPath (Join-Path $runtimeDir 'tailscale-access.json')) {
    & (Join-Path $PSScriptRoot 'disable-phone-access.ps1') -InstallDir $InstallDir
}
Remove-ItemProperty -LiteralPath $runKey -Name 'Codex Switchboard Bridge' -ErrorAction SilentlyContinue

$pidPath = Join-Path $runtimeDir 'bridge.pid'
if (Test-Path -LiteralPath $pidPath) {
    $bridgePidText = (Get-Content -LiteralPath $pidPath -Raw).Trim()
    if ($bridgePidText -match '^\d+$') {
        $process = Get-Process -Id ([int]$bridgePidText) -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -eq 'node') {
            Stop-Process -Id $process.Id -Force
        }
    }
}

if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.previousCcSwitchRun) {
        Set-ItemProperty -LiteralPath $runKey -Name 'CC Switch' -Value $state.previousCcSwitchRun
    }
}

if ($RemoveData -and (Test-Path -LiteralPath $InstallDir)) {
    $resolvedTarget = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $allowedPrefix = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
    if (-not $resolvedTarget.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to recursively remove data outside LocalAppData: $resolvedTarget"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    Write-Output 'SWITCHBOARD_REMOVED_WITH_DATA=True'
} else {
    Write-Output "SWITCHBOARD_DISABLED_DATA_PRESERVED=$InstallDir"
}
