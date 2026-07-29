[CmdletBinding()]
param([string]$InstallDir)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$InstallDir = Get-SwitchboardInstallDir $InstallDir
Start-SwitchboardBridge $InstallDir
$login = Get-BridgeLogin $InstallDir
try {
    $json = $login.Client.GetStringAsync(
        "$($login.BaseUrl)/api/state"
    ).GetAwaiter().GetResult()
    $state = $json | ConvertFrom-Json
    [ordered]@{
        current = $state.current
        providers = $state.providers
        routing = $state.routing
        codex = $state.codex
        operation = $state.operation
        installDir = $InstallDir
    } | ConvertTo-Json -Depth 8
} finally {
    $login.Client.Dispose()
    $login.Handler.Dispose()
}
