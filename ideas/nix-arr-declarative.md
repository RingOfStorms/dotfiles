# Nixarr: Declarative Service Configuration

Status: **~80% complete** in `containers/arr/nixarr.nix`. The stack now runs inside the `arr` floating container on `h001` (`containers/arr/`).

> **In-flight simplification:** We are actively **removing Transmission and the WireGuard VPN namespace** (`nixarr.vpn`, `nixarr.transmission`, and `us_chi_wg_2026-03-15`) in favor of Usenet-only via SABnzbd over TLS. This drops netns routing workarounds, `transmission-rpc-forward`, `jellyfin.vpn.enable = false` overrides, and torrent indexers (`Nyaa.si`, `LimeTorrents`, `The Pirate Bay`), leaving `NZBgeek` + `SABnzbd` as the sole acquisition path.

---

## Current Status Matrix (`containers/arr/nixarr.nix`)

| Service | Declarative Status | Where / How |
|---|---|---|
| **Prowlarr** | ✅ **Done** | `nixarr.prowlarr.settings-sync` (`enable-nixarr-apps = true`, category mappings, indexers with `nzbgeek_api_key_2026-07-15` secret) |
| **Sonarr** | ✅ **~85% Done** | `nixarr.sonarr.settings-sync` (SABnzbd download client via `sabnzbd_api_key_2026-07-15`) + `nixarr.recyclarr` quality profiles (`HD`, `UHD`, `Anime`, `Anime English Dub Only`) & custom formats |
| **Radarr** | ✅ **~85% Done** | `nixarr.radarr.settings-sync` (SABnzbd download client) + `nixarr.recyclarr` (`Remux` profile & custom formats) |
| **Bazarr** | ✅ **~40% Done** | `nixarr.bazarr.settings-sync` (`sonarr.enable = true`, `radarr.enable = true`); subtitle providers & language profiles remain in UI/SQLite |
| **SABnzbd** | ✅ **100% Done** | `services.sabnzbd.configFile = null` (nixpkgs 26.05 declarative `settings.servers` + `settings.categories`) merged at runtime with `/var/lib/sabnzbd-secrets/secrets.ini` (`secretFiles`) |
| **Shelfmark** | ✅ **Enabled** | `nixarr.shelfmark.enable = true` (replaces Readarr); acquisition sources configured in UI |
| **Kavita** | ✅ **Enabled** | `containers/arr/kavita.nix` (replaces Audiobookshelf) |
| **Backups** | ✅ **Done** | Covered nightly by `fleet-backup` (`svc:arr` restic snapshot to B2, including SQLite `.backup` copies) |
| **Transmission / VPN** | 🗑️ **Removing** | Being removed (Usenet-only cutover) |
| **Jellyfin** | ❌ **Pending (Phase 4)** | Still imperative UI state; not yet using `nixarr.jellyfin.api.*` or `jellarr` |
| **Seerr (Jellyseerr)** | ⚠️ **0% (Upstream limitation)** | Renamed `nixarr.seerr.enable = true`; state in `/srv/containers/arr/state/jellyseerr/settings.json` (backed up by `fleet-backup`). Upstream FR [seerr-team/seerr#2772](https://github.com/seerr-team/seerr/issues/2772) still open |

---

## What Remains Worth Doing

### 1. Finish the Transmission + VPN Removal Cutover
- Remove `nixarr.vpn`, `nixarr.transmission`, `jellyfin.vpn.enable = false`, and `transmission.enable = true` in `sonarr`/`radarr` `settings-sync`.
- Remove torrent indexers (`Nyaa.si`, `LimeTorrents`, `The Pirate Bay`) from `nixarr.prowlarr.settings-sync.indexers` (or keep any Usenet indexers added alongside `NZBgeek`).
- Drop `transmission-rpc-forward` and VPN-specific hardening/firewall rules in `containers/arr/container.nix` and `containers/arr/hardening.nix`.
- Remove `us_chi_wg_2026-03-15` secret hydration once unused.

### 2. Reassign Existing Sonarr / Radarr Library Items to Recyclarr Profiles
Per `containers/arr/nixarr.nix:220-221`, Recyclarr profiles (`HD`, `UHD`, `Anime`, `Anime English Dub Only` in Sonarr; `Remux` in Radarr) are created and synced, but existing series/movies were deliberately not bulk-reassigned yet:
- Inventory current root folders, tags, and assigned quality profiles in Sonarr/Radarr.
- Bulk-assign existing shows/movies to the declarative Recyclarr profiles and remove unused legacy profiles.

### 3. Phase 4 — Declarative Jellyfin (`nixarr.jellyfin.api.*` / `jellarr`)
Two options, can be done independently:

1. **Built-in `nixarr.jellyfin.api.*` (low effort):**
   - Completes initial startup wizard, sets admin user from a `sec-agent` secret password file, generates API key file, and pins device UUID.
2. **Layer `services.jellarr` ([venkyr77/jellarr](https://github.com/venkyr77/jellarr)) for libraries, transcoding (Intel QSV), and branding:**
   - Pure REST API (never touches SQLite directly or restarts Jellyfin; selective updates leave watch history untouched).
   - Bootstrap from current state inside the `arr` container:
     ```sh
     jellarr dump > /tmp/jellyfin-current.yml
     ```
   - Translate libraries, QSV hardware acceleration settings, and user settings into `services.jellarr.config`.

### 4. Optional: Move SABnzbd `secrets.ini` into `sec`
Currently `/var/lib/sabnzbd-secrets/secrets.ini` (`/srv/containers/arr/sabnzbd-secrets/secrets.ini` on the host) is managed by hand on `h001` (`containers/arr/nixarr.nix:390-416`) and backed up via `fleet-backup`. Moving its contents into a `sec` key (`machines/high-trust/sabnzbd_secrets_ini`) hydrated by `sec-agent` would eliminate the last hand-managed secret file in `arr`.
