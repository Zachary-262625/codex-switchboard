$ErrorActionPreference = 'Stop'

function Get-SwitchboardInstallDir {
    param([string]$InstallDir)

    if ($InstallDir) {
        return [IO.Path]::GetFullPath($InstallDir)
    }
    return (Join-Path $env:LOCALAPPDATA 'CodexSwitchboard')
}

function Find-TailscaleExecutable {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidate = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return $null
}

function Find-CcSwitchExecutable {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        $resolved = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "CC Switch executable does not exist: $resolved"
        }
        return $resolved
    }

    $command = Get-Command cc-switch.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\CC Switch\cc-switch.exe'),
        (Join-Path $env:LOCALAPPDATA 'CC Switch\cc-switch.exe'),
        (Join-Path $env:ProgramFiles 'CC Switch\cc-switch.exe'),
        (Join-Path $env:ProgramFiles 'CC-Switch\cc-switch.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        $entries = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*CC Switch*' }
        foreach ($entry in $entries) {
            $icon = [string]$entry.DisplayIcon
            if ($icon) {
                $icon = $icon.Trim('"').Split(',')[0]
                if (Test-Path -LiteralPath $icon -PathType Leaf) {
                    return $icon
                }
            }
            if ($entry.InstallLocation) {
                $candidate = Join-Path ([string]$entry.InstallLocation) 'cc-switch.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        }
    }
    return $null
}

function Find-CodexAumid {
    param([string]$ExplicitAumid)

    if ($ExplicitAumid) {
        return $ExplicitAumid
    }
    $app = Get-StartApps -ErrorAction SilentlyContinue |
        Where-Object { $_.AppID -like 'OpenAI.Codex_*!App' } |
        Select-Object -First 1
    if ($app) {
        return [string]$app.AppID
    }
    return $null
}

function Get-BridgeLogin {
    param([string]$InstallDir)

    Add-Type -AssemblyName System.Net.Http
    $baseUrl = Get-SwitchboardBaseUrl $InstallDir
    $passwordPath = Join-Path $InstallDir 'runtime\first-login.txt'
    if (-not (Test-Path -LiteralPath $passwordPath)) {
        throw "Bridge login file not found: $passwordPath"
    }
    $password = (Get-Content -LiteralPath $passwordPath)[-1].Trim()
    if (-not $password) {
        throw 'Bridge login password is empty.'
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $fields = [System.Collections.Generic.Dictionary[string,string]]::new()
    $fields.Add('password', $password)
    $content = [System.Net.Http.FormUrlEncodedContent]::new($fields)
    $response = $client.PostAsync(
        "$baseUrl/login",
        $content
    ).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        $client.Dispose()
        $handler.Dispose()
        throw "Bridge login failed with HTTP $([int]$response.StatusCode)."
    }
    $dashboard = $client.GetStringAsync(
        "$baseUrl/"
    ).GetAwaiter().GetResult()
    $csrf = [regex]::Match($dashboard, 'const csrf="([^"]+)"').Groups[1].Value
    if (-not $csrf) {
        $client.Dispose()
        $handler.Dispose()
        throw 'Bridge CSRF token was not found.'
    }
    return [pscustomobject]@{
        Client = $client
        Handler = $handler
        Csrf = $csrf
        BaseUrl = $baseUrl
    }
}

function Get-SwitchboardBaseUrl {
    param([string]$InstallDir)

    $configPath = Join-Path $InstallDir 'runtime\config.json'
    $port = 17823
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.host -and $config.host -ne '127.0.0.1') {
            throw "Unsafe Bridge host in config: $($config.host)"
        }
        if ($config.port) {
            $port = [int]$config.port
        }
    }
    return "http://127.0.0.1:$port"
}

function Start-SwitchboardBridge {
    param([string]$InstallDir)

    $baseUrl = Get-SwitchboardBaseUrl $InstallDir
    $launcher = Join-Path $InstallDir 'start-bridge.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "Bridge launcher not found: $launcher"
    }
    try {
        $health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 2
        if ($health.ok) {
            return
        }
    } catch {}

    & $launcher
    for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
        Start-Sleep -Milliseconds 250
        try {
            $health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 2
            if ($health.ok) {
                return
            }
        } catch {}
    }
    throw 'Bridge did not become healthy.'
}
