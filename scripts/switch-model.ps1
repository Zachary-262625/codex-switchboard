[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HandoffNote,

    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$InstallDir = Get-SwitchboardInstallDir $InstallDir
Start-SwitchboardBridge $InstallDir
$login = Get-BridgeLogin $InstallDir

function Match-Text {
    param([object]$Provider, [string]$Query, [switch]$Exact)

    $values = @(
        [string]$Provider.id,
        [string]$Provider.name,
        [string]$Provider.model
    ) | Where-Object { $_ }
    foreach ($value in $values) {
        if ($Exact -and $value.Equals($Query, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if (-not $Exact -and $value.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Write-Event {
    param([string]$Phase, [string]$Message, [object]$Provider)

    $safeMessage = $Message -replace '(?i)Bearer\s+\S+', 'Bearer [REDACTED]'
    $event = [ordered]@{
        at = (Get-Date).ToUniversalTime().ToString('o')
        source = 'codex-switchboard-skill'
        providerId = $Provider.id
        providerName = $Provider.name
        phase = $Phase
        message = $safeMessage
    }
    $event | ConvertTo-Json -Compress |
        Add-Content -LiteralPath (Join-Path $InstallDir 'runtime\handoff-events.jsonl') -Encoding UTF8
}

try {
    $stateJson = $login.Client.GetStringAsync(
        "$($login.BaseUrl)/api/state"
    ).GetAwaiter().GetResult()
    $state = $stateJson | ConvertFrom-Json
    $matches = @($state.providers | Where-Object { Match-Text $_ $Target -Exact })
    if ($matches.Count -eq 0) {
        $matches = @($state.providers | Where-Object { Match-Text $_ $Target })
    }
    if ($matches.Count -eq 0) {
        $available = ($state.providers | ForEach-Object {
            "$($_.name) [$($_.model)]"
        }) -join ', '
        throw "No provider matches '$Target'. Available: $available"
    }
    if ($matches.Count -gt 1) {
        $available = ($matches | ForEach-Object {
            "$($_.name) id=$($_.id) model=$($_.model)"
        }) -join '; '
        throw "Provider query '$Target' is ambiguous: $available"
    }
    $provider = $matches[0]

    $handoffPath = Join-Path $InstallDir 'HANDOFF.md'
    $backupPath = Join-Path $InstallDir 'runtime\HANDOFF.last-known-good.md'
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    Add-Content -LiteralPath $handoffPath -Encoding UTF8 -Value @(
        ''
        "## Switch prepared at $timestamp"
        ''
        "- Target: $($provider.name) ($($provider.model))"
        "- Handoff: $HandoffNote"
    )
    Copy-Item -LiteralPath $handoffPath -Destination $backupPath -Force
    Write-Event 'prepared' 'Handoff note appended and last-known-good snapshot created.' $provider

    $login.Client.DefaultRequestHeaders.Remove('x-csrf-token') | Out-Null
    $login.Client.DefaultRequestHeaders.Add('x-csrf-token', $login.Csrf)
    $body = @{ providerId = [string]$provider.id } | ConvertTo-Json -Compress
    $content = [System.Net.Http.StringContent]::new(
        $body,
        [Text.Encoding]::UTF8,
        'application/json'
    )
    Write-Event 'requested' 'Switch request sent to the local Bridge.' $provider
    $response = $login.Client.PostAsync(
        "$($login.BaseUrl)/api/switch",
        $content
    ).GetAwaiter().GetResult()
    $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        throw "Bridge switch failed with HTTP $([int]$response.StatusCode): $responseText"
    }
    Write-Event 'client-confirmed' 'Bridge returned success after switch verification and restart.' $provider
    $responseText
} catch {
    if ($provider) {
        Write-Event 'client-failed' ([string]$_.Exception.Message) $provider
    }
    throw
} finally {
    $login.Client.Dispose()
    $login.Handler.Dispose()
}
