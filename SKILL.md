---
name: codex-switchboard
description: Install and operate a Windows Codex model switchboard using Tailscale, CC Switch, and a local Remote Bridge. Use when the user asks to install or configure Tailscale/CC Switch, deploy or repair the phone console, inspect Codex providers, preserve a handoff before restart, or says phrases such as "切换模型到 X", "使用 codex-switchboard skill 切换模型到 X", "切回 GPT", or "switch Codex to X".
---

# Codex Model Switchboard

Switch Codex Desktop providers without visual mouse automation. Use CC Switch's local Tauri command surface, verify provider/routing/model state, preserve handoff records, and restart Codex only after verification.

This implementation targets Windows. Never expose the Bridge to the public internet.

## Route the request

- For first-time setup, dependency installation, repair, or phone access, follow **Set up or repair**.
- For `切换模型到 X`, `切回 GPT`, `switch model`, or an explicit `$codex-switchboard` invocation, follow **Switch a model**.
- For status or provider discovery, run `scripts/get-status.ps1`.
- For removal, follow **Remove the deployment**.

Read [references/deployment.md](references/deployment.md) before setup or repair. Read [references/architecture.md](references/architecture.md) when diagnosing security, logging, provider resolution, or restart behavior.

## Set up or repair

1. Confirm Windows 10/11 and explain that Tailscale login, CC Switch provider/API configuration, UAC, and a Codex restart can require user interaction.
2. Inspect `winget.exe`, `node.exe`, Tailscale, CC Switch, Codex Desktop, and the current Tailscale login state without changing the machine. Use the detection functions in `scripts/common.ps1` where helpful.
3. Obtain explicit approval before downloading or installing anything. Install only missing software from the sources and commands in [references/deployment.md](references/deployment.md). Do not bundle or execute an opaque all-in-one downloader.
4. Ask the user to sign in to Tailscale and add/test providers inside CC Switch. Never request API keys in chat or place them in logs.
5. Deploy the Bridge. Pass `-CcSwitchExe` when auto-detection cannot find a portable copy:

   ```powershell
   & "$PSScriptRoot\scripts\deploy-bridge.ps1"
   ```

6. Verify local status:

   ```powershell
   & "$PSScriptRoot\scripts\get-status.ps1"
   ```

7. Enable phone access only after the user confirms both devices will use the same Tailnet. This step requires UAC:

   ```powershell
   & "$PSScriptRoot\scripts\enable-phone-access.ps1"
   ```

Return the printed phone URL and a link to the printed password-file path. Recommend adding the page to the phone home screen. Do not create desktop shortcuts.

## Switch a model

1. Run `scripts/get-status.ps1` and resolve the requested target against provider ID, provider name, and configured model. If a query is ambiguous, show the matching providers and ask the user to choose.
2. Before switching, summarize the active task into a short handoff note containing:
   - current user goal;
   - completed work or important state;
   - the safest next step after restart.
3. Tell the user that Codex will restart and the current task may disconnect.
4. Execute:

   ```powershell
   & "$PSScriptRoot\scripts\switch-model.ps1" `
     -Target "<provider name, id, or model>" `
     -HandoffNote "<goal; state; next step>"
   ```

The script appends the note, snapshots `HANDOFF.md`, appends a JSONL `prepared` event, and sends the request. The Bridge independently snapshots again, records `completed` or `failed`, verifies CC Switch routing and the live Codex model, then restarts Codex. Do not add an automatic rollback timer.

Natural-language invocation only works in a Codex task that can still receive the message. If switching front ends hides the original task, use the phone console to switch back; it is intentionally independent of the active AI model.

## Remove the deployment

Run:

```powershell
& "$PSScriptRoot\scripts\uninstall-switchboard.ps1"
```

This removes autostart and Tailnet exposure but preserves runtime logs and handoff files. Delete retained data only when the user explicitly requests it, using `-RemoveData`.

## Safety invariants

- Use official download sources only.
- Use no coordinate-based or visual GUI automation.
- Keep the Node Bridge on `127.0.0.1`; expose only the computer's Tailscale IPv4 through a restricted Windows port proxy and firewall rule.
- Do not use Tailscale Funnel, router port forwarding, `0.0.0.0`, or a LAN-wide firewall rule.
- Do not log passwords, cookies, API keys, tokens, or full provider credentials.
- Do not overwrite provider configuration or silently choose among ambiguous matches.
- Preserve append-only events. Never truncate `runtime/handoff-events.jsonl`.
