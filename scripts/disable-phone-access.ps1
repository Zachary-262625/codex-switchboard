[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$InstallDir = Get-SwitchboardInstallDir $InstallDir
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-InstallDir', "`"$InstallDir`"",
        '-Elevated'
    )
    $process = Start-Process `
        -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -Verb RunAs `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Phone access removal failed with exit code $($process.ExitCode)."
    }
    return
}

$statePath = Join-Path $InstallDir 'runtime\tailscale-access.json'
$ruleName = 'Codex Switchboard Bridge - Tailscale'
$tailscaleIp = $null
$port = 17823
if (Test-Path -LiteralPath $statePath) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $tailscaleIp = $state.tailscaleIp
        $port = [int]$state.port
    } catch {}
}
if ($tailscaleIp) {
    & 'C:\Windows\System32\netsh.exe' interface portproxy delete v4tov4 `
        "listenaddress=$tailscaleIp" "listenport=$port" | Out-Null
}
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Write-Output 'PHONE_ACCESS_REMOVED=True'
