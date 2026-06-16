# SSH Tunnel Manager

A lightweight macOS menu bar app for managing SSH port forwards. No electron, no bloat — just native Swift and AppKit.

<p align="center">
  <img src=".github/menu.png" width="280" alt="Menu bar with grouped tunnels and per-group toggles">
  &nbsp;&nbsp;&nbsp;
  <img src=".github/group.png" width="280" alt="Configuring a group divider">
</p>
<p align="center">
  <img src=".github/settings.png" width="560" alt="Tunnel settings with multiple port forwards">
</p>

## Why?

If you work with remote servers, you constantly need SSH tunnels:
- Database access (`localhost:5432` → production PostgreSQL)
- Internal services (`localhost:8080` → staging API)
- Development proxies

Running `ssh -N -L ...` in terminal works, but:
- You forget which tunnels are running
- They die silently when your laptop sleeps
- You need to remember the exact command for each tunnel

This app solves that. Configure once, connect with one click.

## Features

- **Menu bar app** — always accessible, no dock icon clutter
- **Multiple port forwards per tunnel** — one SSH connection, many `-L` mappings
- **Group tunnels** — organize them with dividers and flip a whole group with one toggle
- **Auto-reconnect** — tunnels automatically reconnect when they drop
- **SSH config aliases** — reuse hosts from your `~/.ssh/config`
- **Launch at login** — start tunnels when your Mac boots
- **Auto-connect** — mark tunnels to connect automatically on app launch
- **Native macOS** — uses system SSH, no bundled binaries

## Alternatives

| App | Issues |
|-----|--------|
| **Core Tunnel** | $10, closed source |
| **Secure Pipes** | Abandoned (last update 2019) |
| **SSH Tunnel Manager (Java)** | Requires JRE, clunky UI |
| **Termius** | Subscription model, overkill for just tunnels |
| **Manual terminal** | No auto-reconnect, easy to forget |

This app is free, open source, and does one thing well.

## Install

Download `SSHTunnelManager.dmg` from [Releases](../../releases).

On first launch, macOS will warn about unsigned app:
1. Right-click the app → Open, or
2. System Settings → Privacy & Security → Open Anyway

## Build from source

```bash
git clone https://github.com/user/ssh-tunnel-manager.git
cd ssh-tunnel-manager/SSHTunnelManager
xcodebuild -scheme SSHTunnelManager -configuration Release
```

Requires Xcode 15+ and macOS 14+.

## Usage

1. Click the network icon in menu bar
2. Click "Settings" to add tunnels
3. Toggle tunnels on/off from the menu bar

Config is stored in `~/Library/Application Support/SSHTunnelManager/tunnels.json`.

## License

MIT
