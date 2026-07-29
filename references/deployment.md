# Windows deployment

## Supported scope

The bundled Remote Bridge is Windows-only. It expects:

- Windows 10 or 11;
- Codex Desktop installed from the Microsoft Store;
- Node.js LTS;
- Tailscale signed in on the computer and phone;
- CC Switch with at least one Codex provider already configured and tested.

Provider secrets stay in CC Switch. Do not collect them in chat.

## Official sources

- Tailscale: `https://tailscale.com/download/windows`
- CC Switch: `https://github.com/farion1231/cc-switch/releases`
- Node.js: the `OpenJS.NodeJS.LTS` package from Windows Package Manager

After explicit user approval, install Tailscale and Node.js through Windows Package Manager:

```powershell
winget install --id Tailscale.Tailscale --exact --accept-package-agreements --accept-source-agreements
winget install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements
```

For CC Switch, open the official GitHub Releases page and download the latest `Windows.msi`, or use a portable copy supplied by the user. Confirm the download belongs to `github.com/farion1231/cc-switch`. Do not substitute third-party download sites or collect provider credentials.

## Setup sequence

1. Detect existing dependencies without modifying the machine.
2. Obtain approval before installation.
3. Install only missing dependencies from the official commands and sources above.
4. Have the user finish Tailscale sign-in.
5. Open CC Switch and create or import Codex providers. Test each target in CC Switch.
6. Run `deploy-bridge.ps1`. If CC Switch is portable, pass its full executable path with `-CcSwitchExe`.
7. Run `get-status.ps1`. Confirm provider names/models and that the Bridge responds.
8. Run `enable-phone-access.ps1`, accept UAC, and verify the returned Tailscale URL from the phone.

## User interaction boundaries

- Tailscale identity login happens in the user's browser.
- API keys and subscription credentials are entered directly in CC Switch.
- UAC is expected for MSI installation, the IP Helper service, Windows port proxy, and firewall changes.
- A model switch terminates and relaunches Codex Desktop, so the task invoking it may not deliver a final message.

## Repair

Rerun deployment scripts safely:

- `deploy-bridge.ps1` refreshes program files while preserving runtime authentication and logs.
- `enable-phone-access.ps1` replaces only the named Switchboard port-proxy entry and firewall rule.
- Rerun phone access configuration after the computer's Tailscale IPv4 changes.

Do not redeploy over a running operation. Check `get-status.ps1` first.
