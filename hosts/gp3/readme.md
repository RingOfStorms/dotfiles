# gp3

Trusted mobile work laptop (GPD Pocket 3). Re-imaged from the old low-trust TV box; see utilities/nixos-install-disko/readme.md.

## Hardware

| Component | Spec |
|---|---|
| Model | GPD Pocket 3 (G1621-02) |
| CPU | Intel Core i7-1195G7 (4C/8T, up to 5.0 GHz) |
| GPU | Intel Iris Xe (integrated) |
| RAM | 16 GB |
| Storage | Not yet inventoried |
| Display | 8" 1920x1200 touchscreen (rotated panel) |

## Re-image / first boot (sec-agent)

Install per `utilities/nixos-install-disko/readme.md` steps 1-6. Its step 7
describes the retired OpenBao/vault-agent flow; for gp3 (sec-agent) do this
instead:

1. **Zitadel** (`https://sso.joshuabell.xyz`): machine user `gp3`
   (sub `364267179626987523`). In the secrets project (`344379162166820867`)
   authorizations, replace `device_low_trust` with `device_high_trust`.
   Under **Keys → + New → JSON**, create a fresh key (the old one was on the
   wiped disk); delete the old keys.
2. **Seed the key.** `/machine-key.json` is bind-mounted from `/persist`. From
   the installer before rebooting (with `/mnt/persist` mounted):
   ```sh
   scp key.json root@<ip>:/mnt/persist/machine-key.json
   ssh root@<ip> 'chmod 400 /mnt/persist/machine-key.json'
   ```
   Or after the first boot, write it to `/persist/machine-key.json` and bind
   it to `/machine-key.json`.
3. **Fetch secrets.** The agent reaches `https://secrets.joshuabell.xyz`
   publicly (via o002), so it works before tailnet join:
   ```sh
   sudo systemctl restart sec-agent && journalctl -u sec-agent -f
   sudo ls /var/lib/secrets_manager_hydrated/
   ```
   Expected secrets: `headscale_auth_2026-03-15`, `nix2nix_*`, `nix2github_*`,
   `nix2gitforgejo_*`, `github_read_token_*` and `atuin-key-josh_*`.
4. **Tailnet.** Delete the old low-trust node first
   (`ssh o002 'sudo headscale nodes list' | grep gp3`, then
   `sudo headscale nodes delete --identifier <id>`). Then on gp3:
   `sudo systemctl restart tailscaled-autoconnect`.
5. **Deploy from lio** from now on (root key installed):
   `nixos-rebuild --flake ./hosts/gp3#gp3 --target-host root@gp3 ...`
