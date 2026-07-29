[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$InstallDir = Get-SwitchboardInstallDir $InstallDir
Start-SwitchboardBridge $InstallDir

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
        throw "Phone access configuration failed with exit code $($process.ExitCode)."
    }
    Get-Content -LiteralPath (Join-Path $InstallDir 'runtime\tailscale-access.json') -Raw -Encoding UTF8
    return
}

$tailscaleExe = Find-TailscaleExecutable
if (-not $tailscaleExe) {
    throw 'Tailscale was not found.'
}
$baseUrl = Get-SwitchboardBaseUrl $InstallDir
$uri = [Uri]$baseUrl
$port = $uri.Port
$tailscaleIp = (& $tailscaleExe ip -4 | Select-Object -First 1).Trim()
$parsedIp = $null
if (-not [Net.IPAddress]::TryParse($tailscaleIp, [ref]$parsedIp)) {
    throw 'Tailscale did not return a valid IPv4 address. Sign in first.'
}
$bytes = $parsedIp.GetAddressBytes()
if ($bytes.Count -ne 4 -or $bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) {
    throw "Refusing a non-Tailscale IPv4 address: $tailscaleIp"
}

$runtimeDir = Join-Path $InstallDir 'runtime'
$statePath = Join-Path $runtimeDir 'tailscale-access.json'
$ruleName = 'Codex Switchboard Bridge - Tailscale'
$previousIp = $null
if (Test-Path -LiteralPath $statePath) {
    try {
        $previousIp = (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json).tailscaleIp
    } catch {}
}

Set-Service -Name iphlpsvc -StartupType Automatic
Start-Service -Name iphlpsvc
$netsh = 'C:\Windows\System32\netsh.exe'
if ($previousIp -and $previousIp -ne $tailscaleIp) {
    & $netsh interface portproxy delete v4tov4 "listenaddress=$previousIp" "listenport=$port" | Out-Null
}
& $netsh interface portproxy delete v4tov4 "listenaddress=$tailscaleIp" "listenport=$port" | Out-Null
& $netsh interface portproxy add v4tov4 `
    "listenaddress=$tailscaleIp" "listenport=$port" `
    'connectaddress=127.0.0.1' "connectport=$port" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Windows port proxy failed with exit code $LASTEXITCODE."
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule `
    -DisplayName $ruleName `
    -Description 'Allow Codex Switchboard only through the Tailscale IPv4 range.' `
    -Direction Inbound `
    -Action Allow `
    -Enabled True `
    -Profile Any `
    -Protocol TCP `
    -LocalAddress $tailscaleIp `
    -LocalPort $port `
    -RemoteAddress '100.64.0.0/10' | Out-Null

$dnsName = $null
try {
    $tailscaleStatus = (& $tailscaleExe status --json | Out-String) | ConvertFrom-Json
    $dnsName = ([string]$tailscaleStatus.Self.DNSName).TrimEnd('.')
} catch {}
$phoneUrl = if ($dnsName) {
    "http://${dnsName}:$port/"
} else {
    "http://${tailscaleIp}:$port/"
}
$state = [ordered]@{
    configuredAt = (Get-Date).ToUniversalTime().ToString('o')
    tailscaleIp = $tailscaleIp
    dnsName = $dnsName
    port = $port
    phoneUrl = $phoneUrl
    backupUrl = "http://${tailscaleIp}:$port/"
    firewallRule = $ruleName
    passwordFile = Join-Path $runtimeDir 'first-login.txt'
}
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

$health = Invoke-RestMethod -Uri "http://${tailscaleIp}:$port/health" -TimeoutSec 8
if (-not $health.ok) {
    throw 'The Tailscale Bridge health check failed.'
}
$state | ConvertTo-Json -Depth 4
