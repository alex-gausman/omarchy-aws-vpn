# AWS VPN for Omarchy

Omarchy bar widget for the [AWS Client VPN](https://aws.amazon.com/vpn/client-vpn-download/) Linux client, driven by its `aws-vpn-client` CLI.

## Features

- Bar icon shows the VPN state: bright when connected, dim when disconnected, pulsing while connecting or disconnecting. The tooltip shows the status and profile.
- **Left click** opens the panel. **Right click** connects or disconnects the selected profile. **Middle click** refreshes.
- The panel has an on/off switch, tunnel traffic counters, how long the tunnel has been up, and a profile list.
- Click a profile to connect to it. If another profile is connected, it is disconnected first. Click the connected profile to disconnect it.
- The selected profile is saved as `profile` in this widget's `shell.json` entry.
- A desktop notification is sent when a connection comes up.

## Keyboard (inside the panel)

- `j` / `k` or arrows: move the cursor
- `enter` / `space`: activate the row (toggle the VPN, or connect to a profile)
- `t`: toggle the VPN
- `d`: disconnect
- `r`: refresh
- `esc`: close

## IPC

```bash
omarchy-shell alex.aws-vpn status           # e.g. "Connected · initech"
omarchy-shell alex.aws-vpn toggleVpn
omarchy-shell alex.aws-vpn connect <profile>
omarchy-shell alex.aws-vpn disconnect
omarchy-shell alex.aws-vpn toggle           # open/close the panel
```

To add a Hyprland keybinding, call one of these commands.

## Requirements

- `aws-vpn-client` on `PATH`, with at least one profile imported (`aws-vpn-client import-profile ...`)

## Install

```bash
omarchy plugin add <git-url> --enable --yes
```

You can also install it by hand for development:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/alex.aws-vpn
omarchy-shell shell rescanPlugins
omarchy plugin enable alex.aws-vpn
```

## Settings

| Key                  | Default | Meaning                                    |
|----------------------|---------|--------------------------------------------|
| `refreshIntervalSec` | `10`    | Status poll interval (1s while connecting) |
| `profile`            | `""`    | Preferred profile when none is connected   |
