# Architecture and guarantees

## Control path

The Bridge launches CC Switch with a per-process WebView2 remote-debugging port bound to `127.0.0.1` and invokes CC Switch's own Tauri commands through Chrome DevTools Protocol. It does not move the mouse or depend on hover-only buttons.

The switch sequence is:

1. Resolve a configured Codex provider.
2. Append a human handoff note.
3. Copy `HANDOFF.md` to `runtime/HANDOFF.last-known-good.md`.
4. Append a `prepared` JSONL event.
5. Ask CC Switch to enable or disable Codex local-routing takeover as required.
6. Switch the provider.
7. Verify current provider, route readiness, and live `~/.codex/config.toml` model.
8. Restart Codex Desktop.
9. Append `completed` or `failed`.

No rollback timer is created.

## Installed layout

Default root: `%LOCALAPPDATA%\CodexSwitchboard`

- `server.mjs`: loopback Bridge and phone console
- `start-bridge.ps1`: hidden current-user launcher
- `HANDOFF.md`: human-readable handoff history
- `runtime/config.json`: local paths, password hash, and Bridge settings
- `runtime/first-login.txt`: initial phone-console password
- `runtime/HANDOFF.last-known-good.md`: pre-switch snapshot
- `runtime/handoff-events.jsonl`: append-only machine events
- `runtime/bridge.log`: redacted operational log

## Network boundary

The Bridge listens only on `127.0.0.1:17823`. Phone access uses:

`Tailscale IPv4:17823 -> 127.0.0.1:17823`

The firewall rule restricts the local address to the computer's Tailscale IP and the remote range to `100.64.0.0/10`. HTTP contents travel inside Tailscale's encrypted tunnel. This is not permission to expose the port through Funnel, a router, or a public cloud proxy.

## Conversation limitation

The Skill can react to `切换模型到 X` only while an active Codex task can receive the message. A different model front end may not display the same task history. The phone console is the durable out-of-band recovery mechanism; the handoff files preserve operational context but do not synchronize proprietary chat databases.
