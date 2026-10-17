# h003

Containers host for floating services (`containers/README.md`). It runs little
else. Until 2026-10-15 it was the home router; that role moved to h005
(`hosts/h005/readme.md`, switch notes in `hosts/h005/switch_readme.md`). The
router config is preserved in git history before the re-image commit.

## Hardware

| Component | Spec |
|---|---|
| Model | M5 PLUS mini PC (v1.0) |
| CPU | AMD Ryzen 7 5825U (8C/16T, up to 4.55 GHz) |
| GPU | AMD Barcelo (integrated, VAAPI) |
| RAM | 32 GB |
| Storage | NVMe (encrypted bcachefs root + impermanence) |
| Network | enp1s0 / enp2s0 (2.5 GbE); one port to a VLAN 20 access port, plain DHCP |

Unlocks unattended from an encrypted USB key stick (password `usbKeyPassword` in
`flake.nix`); without it, it prompts for the disk passphrase on the console.
Container state lives under `/persist` (`containers.nix`).

## Bare-metal services

None besides host plumbing: nginx (for floating sites), sec-agent,
beszel-agent, fail2ban, tailscaled. Floating containers: `cnt ls`.
## Re-image procedure

Follow `utilities/nixos-install-disko/readme.md`.

1. Before wiping: nothing on h003 needs saving (router state lives on h005; the
   minecraft backup is on h001). Optionally `headscale nodes delete` the old
   h003 node on o002 so the new install re-registers cleanly.
2. Re-cable: one NIC to a **VLAN 20 access port** on the switch (no trunk).
3. Boot the installer ISO, SSH in. Disko single-drive, **encrypted**, target the
   NVMe by id. Make the USB key stick with `usbKeyPassword`
   (`utilities/nixos-install-disko/usb_key.md`), label it "h003 key", leave it
   plugged in.
4. `nixos-generate-config --no-filesystems --root /mnt`; replace the
   placeholder `hardware-configuration.nix`.
5. Fill `boot`/`primary`/`swap` (`TODO-*`) in `flake.nix` from
   `lsblk -o name,uuid,partuuid` (swap by PARTUUID). Commit, build on lio,
   copy and install (install readme, step 6).
6. Seed the existing Zitadel machine user's **new** key into
   `/mnt/persist/machine-key.json` (step 7) and reboot.
7. Verify: sec-agent hydrates, `tailscale ip -4` (update `overlayIp` here and
   in `hosts/fleet.nix` if it changed), Beszel reports, reboot twice (root
   wipes, `/persist` keeps), then once without the stick for the prompt.
8. `cnt` sanity: deploy `hello-nixos` to h003, check, remove.
