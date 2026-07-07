# SSH Tunnel Manager

A lightweight macOS menu bar app for managing SSH port forwards. No electron, no bloat — just native Swift and AppKit.

<p align="center">
  <img src=".github/menu.png" width="30%" alt="Menu bar with grouped tunnels and per-group toggles">
</p>
<p align="center">
  <img src=".github/settings.png" width="80%" alt="Tunnel settings with a local port forward">
</p>
<p align="center">
  <img src=".github/group.png" width="80%" alt="Grouped tunnels with a divider in the settings sidebar">
</p>

## Why?

If you work with remote servers, you constantly need SSH tunnels:
- Database access (`localhost:5432` → production PostgreSQL)
- Internal services (`localhost:8080` → staging API)
- A SOCKS proxy into a private network (`ssh -D`)

Running `ssh -N -L ...` in terminal works, but:
- You forget which tunnels are running
- They die silently when your laptop sleeps
- You need to remember the exact command for each tunnel

This app solves that. Configure once, connect with one click.

## Features

- **Menu bar app** — always accessible, no dock icon clutter
- **Multiple port forwards per tunnel** — one SSH connection, many `-L` / `-R` mappings
- **SOCKS proxy** — per-mapping dynamic forwarding (`ssh -D`), mixable with local forwards
- **Remote forwards** — expose a local service through the server (`ssh -R`) — a self-hosted way out
- **Jump host** — reach a host behind a bastion (`ssh -J`), multi-hop chains included
- **Group tunnels** — organize them with dividers and flip a whole group with one toggle
- **Auto-reconnect** — tunnels automatically reconnect when they drop
- **Failure reasons** — a failed or dropped tunnel shows *why* (auth, refused, unreachable, DNS, host-key change, port in use), not just "disconnected"
- **Connect/disconnect alerts** — optional sound and notification when a tunnel drops or comes back
- **Port-conflict guard** — warns when two tunnels want the same local port and stops them from clobbering each other
- **Per-tunnel tuning** — `ConnectTimeout`, keepalive, compression, "survive brief network drops", host-key options, and a free-text field for any other ssh flags
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

### Homebrew

```bash
brew install --cask 0fuz/tap/ssh-tunnel-manager
```

The app is not notarized, so if macOS blocks the first launch, right-click it in
`/Applications` and choose Open, or install without the Gatekeeper prompt:

```bash
brew install --cask --no-quarantine 0fuz/tap/ssh-tunnel-manager
```

### Direct download

Download `SSHTunnelManager.dmg` from [Releases](../../releases).

On first launch, macOS will warn about unsigned app:
1. Right-click the app → Open, or
2. System Settings → Privacy & Security → Open Anyway

## Build from source

```bash
git clone https://github.com/0fuz/ssh-tunnel-manager.git
cd ssh-tunnel-manager/SSHTunnelManager
xcodebuild -scheme SSHTunnelManager -configuration Release
```

Requires Xcode 15+ and macOS 14+.

## Usage

1. Click the network icon in menu bar
2. Click "Settings" to add tunnels
3. Toggle tunnels on/off from the menu bar

Config is stored in `~/Library/Application Support/SSHTunnelManager/tunnels.json`.

### SOCKS proxy

Set a port mapping's type to **SOCKS** for a dynamic proxy (`ssh -D`). Point your browser, system proxy, or a tool at `127.0.0.1:<port>`. When the tunnel is connected, the detail view's **Usage** section has the address and `socks5h://` / `socks5://` URLs ready to copy.

Use `socks5h://` when DNS should be resolved **on the server** — e.g. to reach internal hostnames behind it; `socks5://` resolves DNS locally:

```bash
curl -x socks5h://127.0.0.1:1080 http://internal-host:8080
```

### Jump host (bastion)

When a host has no public route and is only reachable through a bastion, set the target as the **Host** and the bastion as the **Jump Host** (in the tunnel's *Advanced* section). The app adds `ssh -J`, so the login is routed through the bastion while the forward still targets the final host — the jump host is only a login path, not part of the data flow.

Example — reach a Postgres box `db.internal` that only the bastion can see:

- **Host**: `db.internal`  **Jump Host**: `you@bastion.example.com`
- **Local Forward**: Local `127.0.0.1:5432` → Remote `127.0.0.1:5432`

Then point your client at `localhost:5432`. Chain multiple hops with commas: `you@bastion,you@inner-gateway`.

### Remote forward (expose a local service)

A **Remote Forward** (`ssh -R`) is the reverse of a local forward: the server listens on a port and sends connections back to your Mac — handy for showing a local site to the outside world through a public server, catching a webhook, or reverse SSH. As with the other types, **Local** is always this Mac and **Remote** is the server.

Example — make a local site (`localhost:3000`) reachable at the server's public address:

- **Host**: your public server
- **Remote Forward**: Local `127.0.0.1:3000` → Remote `0.0.0.0:8080`

Now `http://your-server:8080` reaches your Mac's `localhost:3000`. Binding to `0.0.0.0` (rather than the server's own loopback) needs **`GatewayPorts yes`** in the server's `sshd_config`; without it the port is reachable only from the server itself.

### Connection alerts

The app can play a sound and/or show a notification when a tunnel connects or drops unexpectedly. Toggle them in **Preferences** (the gear in the sidebar footer) — sounds are on by default, notifications off. Manual disconnects and config edits stay silent; only genuine drops alert.

Notifications need macOS permission. Turning **Show Notifications** on prompts for it the first time. If notifications still don't appear, open **System Settings → Notifications → SSH Tunnel Manager** and make sure **Allow Notifications** is on — for an unsigned build you may have to enable it there by hand.

### When a tunnel won't connect

A failed or dropped tunnel shows the reason in the menu bar and in its detail view — authentication failed, connection refused, host unreachable, DNS, a changed host key, or a local port already in use — so you know whether to check your key, the server, or your network. The reason sticks until the tunnel reconnects or you stop it. Tunnels that are simply switched off stay grey; red means a real problem.

Two tunnels can't share a local forward port. The settings flag the clash as you type the port, and at connect time the second tunnel reports the port is in use instead of fighting the first — then connects on its own once the port frees.

### Connection options

Each tunnel's detail view exposes a few SSH options for awkward hosts:

- **Connect Timeout / Alive Interval / Alive Count** — how long to wait for the connection, and how aggressively to probe a quiet one before declaring it dead.
- **Compression** (`-C`) — trade CPU for bandwidth on slow links.
- **Survive brief network drops** — keep the tunnel up through short outages (`TCPKeepAlive=no`), relying on the keepalive probes above instead of TCP-level teardown.
- **Skip host key check** — for hosts recreated on the same address. Insecure (disables host-key verification); off by default.
- **Extra SSH options** — a free-text escape hatch for ssh flags the UI doesn't cover, e.g. `-o ConnectTimeout=5`. Appended to the command as-is, split on spaces.
- **Jump Host** (`-J`) — route the login through one or more bastions to reach the host. See [Jump host (bastion)](#jump-host-bastion) above.

## License

MIT

---

<sub>Built with AI assistance and human review — every change is tested before release.</sub>
