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
