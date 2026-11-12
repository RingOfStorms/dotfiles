# lio

Primary desktop workstation

## Hardware

| Component | Spec |
|---|---|
| Model | System76 Thelio (thelio-r4) |
| CPU | AMD Ryzen 9 9950X (16C/32T, up to 5.76 GHz) |
| GPU | AMD Radeon RX 7900 GRE + Radeon integrated |
| RAM | 64 GB |
| Storage | Not yet inventoried |
| Displays | Samsung C34J79x 34" 3440x1440 100 Hz; ASUS PG43U 43" 4K 60 Hz |

## Bare-metal services

| Service | Notes |
|---|---|
| nix-serve | Binary cache for the fleet |
| libvirtd | Local VMs |
| nginx | Floating sites |
| Per-host agents | sec-agent, fleet-agent, fail2ban, tailscaled |

## Hex

Hex v3.4.0 starts with Josh's graphical session and downloads its default
model at login. Hold Right Alt to dictate and paste with Ctrl+V. Right Alt is
mapped to F19 and no longer acts as Alt or AltGr; Left Alt and Fcitx5/Mozc
remain available. KDE may ask to approve Hex's global shortcut and remote
keyboard control for paste. A fresh Plasma login is needed for the keyboard
layout change. Hex is the only dictation integration and is enabled only on lio;
the legacy Fcitx5 speech-to-text addon has been removed. Hex's Nix guide does not
claim KDE Wayland support.

The KDE portal's remote-control-start popup is disabled for all apps on lio;
permission prompts and the active-session indicator remain enabled.

## OMP and Blender

OMP's `~/.omp/agent/mcp.json` is local and editable. The existing Blender
server entry is preserved on the first switch and uses `blender-mcp` from
PATH, so it continues to work after package updates. To add it manually:

```json
{ "mcpServers": { "blender": { "command": "blender-mcp", "args": [] } } }
```

The Blender MCP add-on runs generated Python with Blender's user privileges;
sandboxing the OMP process does not sandbox Blender.
