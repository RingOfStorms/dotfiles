# Nixarr: Declarative Service Configuration (future plan)

Captured 2026-05-10 from research into the current state of declarative
configuration support for the nixarr media stack and adjacent tooling.

This file is a **forward-looking plan**, not a record of work already done.
Nothing in here has been applied yet. Current production state on h001 is
nixarr enabled with imperative UI configuration for everything except
Transmission (which already uses `extraSettings` passthrough).

## Status / TL;DR

- **Goal:** move as much *arr / Jellyfin / Bazarr / Prowlarr configuration
  as possible from "click around the UI" into Nix, so the stack is
  reproducible from a fresh state dir.
- **Realistic ceiling today: ~80–90% declarative.** The remaining ~10%
  has no community tooling and would have to stay imperative:
  - **Jellyseerr**: 0% declarative. Upstream FR
    [seerr-team/seerr#2772](https://github.com/seerr-team/seerr/issues/2772)
    is open, no ETA.
  - **SABnzbd Usenet servers / categories / post-processing**: no tool exists.
    Nixarr exposes only port/hostnames/VPN/firewall.
  - **Bazarr subtitle providers / language profiles**: no tool exists.
    Nixarr `settings-sync` covers only the *arr connection wiring.
- **Non-destructive path exists.** Every phase below is independently
  revertible and won't touch user-visible data (watch history, request
  history, download queue, library DB).
- **Prerequisite:** our current `nixarr` flake pin (Nov 2025) likely
  predates the new `settings-sync` machinery shipped on `main`. Phase 0
  is bumping the input.

## 1. Why this changed in 2025/2026

Up until ~mid-2025 the only paths to declarative *arr config were:

- **Buildarr** (Python, full-stack: indexers, download clients, root
  folders, quality profiles, app linking). **Effectively abandoned** —
  last commit 2024-05-04. Don't bet on it.
- **Flemmarr** — abandoned (author no longer uses *arrs).
- **Recyclarr** — only quality profiles + custom formats + naming.
  Excellent at its scope but doesn't touch indexers or download clients.

In late 2025 / early 2026, **nixarr itself** added a first-class
"Settings Sync" subsystem: per-service systemd one-shots that run after
each app starts and PUT/POST configuration to the app's REST API based
on a Nix attrset. Schemas are discoverable via a new `nixarr show-*-schemas`
CLI. Secrets are read from on-disk files and never enter the Nix store.

This subsystem currently covers:

- **Prowlarr**: indexers, tags, applications (with a one-line
  `enable-nixarr-apps = true` to auto-register all enabled *arrs).
- **Sonarr/Radarr**: download clients (Transmission shortcut + generic
  list).
- **Bazarr**: Sonarr/Radarr connection wiring (host, port, API key,
  monitored-only filtering).
- **Jellyfin**: wizard completion, admin user from password file, API
  key file generation, device UUID.

It does **not** cover quality profiles / custom formats (use
`nixarr.recyclarr.*`, also already in nixarr), root folders, import
lists, notifications, *arr indexer connections (these come for free via
Prowlarr's "apps" sync once Prowlarr is configured), Jellyfin libraries
or transcoding (use Jellarr layered on top), or anything in
Jellyseerr/SABnzbd/Bazarr-providers.

## 2. Coverage matrix for our exact service set

Current h001 services (per `hosts/h001/mods/nixarr.nix`): jellyfin,
jellyseerr, sabnzbd, transmission, prowlarr, sonarr, radarr, bazarr.

| Service | Today | After this plan | Tool |
|---|---|---|---|
| Transmission | 100% declarative ✅ (already using `extraSettings`) | 100% | nixarr (existing) |
| Prowlarr | 0% | 100% (indexers + apps) | `nixarr.prowlarr.settings-sync.*` |
| Sonarr | 0% | ~85% (download clients + indexers via Prowlarr + quality via Recyclarr; root folders / import lists / notifications still UI) | `nixarr.sonarr.settings-sync` + `nixarr.recyclarr` |
| Radarr | 0% | ~85% (same shape, same gaps) | same |
| Bazarr | 0% | ~40% (only *arr connection wiring; providers + language profiles still UI) | `nixarr.bazarr.settings-sync` |
| Jellyfin | 0% | ~90% (wizard + admin + API key via nixarr; libraries + transcoding + branding via Jellarr) | `nixarr.jellyfin.api.*` + `services.jellarr` |
| Jellyseerr | 0% | **0%** — fully manual, no upstream support | none |
| SABnzbd | ~5% (port/hostnames) | ~5% — Usenet servers/categories still UI | none |

## 3. Hard prerequisite for `settings-sync`

The new sync services need API access without auth from localhost. We
must add the following to the existing `nixarr.nix` (or wherever the
`nixarr.*` block lives):

```nix
services.prowlarr.settings.auth.required = "DisabledForLocalAddresses";
services.sonarr.settings.auth.required   = "DisabledForLocalAddresses";
services.radarr.settings.auth.required   = "DisabledForLocalAddresses";
```

Bazarr's settings-sync uses the API key directly and doesn't need this.

## 4. Phased migration plan (each phase independently revertible)

### Phase 0 — Update nixarr & inspect

- Bump the `nixarr` input in `hosts/h001/flake.nix` to latest `main`.
- Read the upstream CHANGELOG for breaking changes since the current
  pin (Nov 2025). Notable so far: **Readarr removed in favor of
  `shelfmark`** (we don't use Readarr — informational only).
- Verify `nixos-rebuild build --flake .#h001` still evaluates cleanly
  before deploying.
- Try the new `nixarr` CLI on h001: `nixarr fix-permissions`,
  `nixarr list-api-keys`, `nixarr show-prowlarr-schemas`,
  `nixarr show-sonarr-schemas`, `nixarr show-radarr-schemas`.

### Phase 1 — Recyclarr (lowest risk, highest value)

- Uncomment `recyclarr.enable = true;` at
  `hosts/h001/mods/nixarr.nix:51`.
- Provide `nixarr.recyclarr.configuration` as a Nix attrset using
  TRaSH-Guides templates for our chosen profiles (decision pending —
  see open questions).
- **Run with `delete_old_custom_formats: false` initially** so existing
  manually-created CFs aren't deleted.
- Verify in Sonarr/Radarr that profiles + custom formats appear and
  scoring matches expectations. After a few days of confidence,
  optionally flip to `true`.

### Phase 2 — Prowlarr settings-sync

- Add `nixarr.prowlarr.settings-sync.enable-nixarr-apps = true;`. This
  registers Sonarr/Radarr/Bazarr in Prowlarr's "Apps" page using
  existing API keys — **zero data risk**. Idempotent.
- Then add a small set of indexers via
  `nixarr.prowlarr.settings-sync.indexers`. Discover field names via
  `nixarr show-prowlarr-schemas indexer <implementation>`.
- For private trackers, secrets (cookies, API keys) go through the
  existing openbao secrets pipeline as files referenced by
  `apiKey.secret = "/run/secrets/...";`. **Do not put secrets in the
  Nix store.**
- Once Prowlarr has its indexers + apps declared, the indexers
  automatically propagate to Sonarr/Radarr via Prowlarr's own daemon —
  no per-*arr indexer config needed.

### Phase 3 — *arr download clients & Bazarr connections

```nix
nixarr.sonarr.settings-sync.transmission.enable = true;
nixarr.radarr.settings-sync.transmission.enable = true;
nixarr.bazarr.settings-sync.sonarr.enable = true;
nixarr.bazarr.settings-sync.radarr.enable = true;
```

Outcome: download clients and Bazarr↔*arr wiring are now declarative.
Subtitle providers and language profiles still need UI setup.

### Phase 4 — Jellyfin

Two sub-steps; (a) is built into nixarr, (b) is an external tool.

**(a)** Adopt `nixarr.jellyfin.api.*`:

- Wizard completion
- Admin user from a password file (sourced from openbao)
- API key file generation
- Device UUID

**(b)** Layer `services.jellarr` (https://github.com/venkyr77/jellarr,
v0.1.0 2026-01-24, active) for libraries / transcoding / branding /
plugin repos. Why Jellarr over `Sveske-Juice/declarative-jellyfin`:

- Pure REST API; never restarts Jellyfin or touches the SQLite DB.
- Selective updates — fields you don't list are left alone.
- Has a `dump` command to bootstrap from current state.
- The older `declarative-jellyfin` README itself recommends Jellarr.

Procedure:

1. On h001, run `jellarr dump > /tmp/jellyfin-current.yml` to capture
   our existing libraries/users/transcoding settings.
2. Trim and translate that YAML into a Nix attrset under
   `services.jellarr.config`.
3. Use Jellarr's NixOS bootstrap mode to seed our sops/openbao-managed
   API key into the Jellyfin DB on first apply (one-time only).
4. Watch history is in unrelated DB tables — Jellarr doesn't touch
   them.

### Phase 5 — Document & back up the imperative remainder

For the services that can't be declared, add a comment block to
`hosts/h001/mods/nixarr.nix` listing them and where their state lives,
and ensure the paths are covered by our backup story (cf.
`ideas/service_backups.md`):

| Service | State path | Notes |
|---|---|---|
| Jellyseerr | `/var/lib/nixarr/state/jellyseerr/settings.json` | Contains runtime-generated `clientId` / `vapidPrivate` — back up but **do not template** from Nix |
| SABnzbd | `/var/lib/nixarr/state/sabnzbd/sabnzbd.ini` | Usenet servers, categories, API key |
| Bazarr | `/var/lib/nixarr/state/bazarr/config/config.ini` + `db/bazarr.db` | Providers, language profiles, scoring |

A periodic snapshot of these into a private git repo (or restic/borg
target) gives us a known-good restore path that survives a state-dir
wipe.

## 5. Open questions to decide before executing

1. **Phase scope per PR.** All five phases together, or
   Phase 0 + 1 (update + Recyclarr) first to validate the workflow,
   then Phase 2+ in a follow-up?
2. **TRaSH profile preference for Recyclarr.** Canonical
   "WEB-1080p" + "WEB-2160p"? "HD Bluray + WEB"? Anime-included variants?
3. **Indexers to declare in Phase 2.** Public only (1337x, TPB, etc.)
   or also private trackers via the existing openbao secrets pipeline?
4. **Jellyfin tool choice in Phase 4(b).** Confirm Jellarr (recommended)
   or fall back to `declarative-jellyfin`. Or: skip 4(b) entirely and
   only adopt nixarr's built-in `jellyfin.api.*`.
5. **`nixarr.exporters.enable = true`?** Unrelated to declarative
   config, but a one-line win for our existing `monitoring_hub` —
   exposes Prometheus exporters for every *arr + Transmission + node +
   WireGuard. Worth bundling into Phase 0.

## 6. Things that won't work / don't try

- **Templating Jellyseerr `settings.json` from Nix.** It contains
  runtime-generated secrets (`vapidPublic`, `vapidPrivate`, `clientId`)
  Jellyseerr writes on first boot. Overwriting them invalidates push
  subscriptions and may invalidate sessions. Wait for upstream FR #2772.
- **Buildarr.** Last commit 2024-05-04. Nixarr issue #3 (Buildarr
  integration) has been open since Feb 2024 with no progress; the
  project chose `settings-sync` as its path forward instead.
- **Flemmarr.** Abandoned, non-idempotent, author publicly disinterested.
- **`Sveske-Juice/declarative-jellyfin` (default choice).** Still
  maintained but pokes Jellyfin's SQLite DB directly and restarts
  Jellyfin during apply. Track record of breakage on Jellyfin upgrades
  (cf. its own issue #13). Use Jellarr instead unless we have a
  specific reason.
- **Profilarr.** It's a centralized web app for managing CFs across
  multiple *arrs — not config-as-code. Useful as a GUI complement but
  not a Nix-native solution. Tracked upstream as nixarr issue #87.

## 7. Reference links

- Nixarr repo (org renamed): https://github.com/nix-media-server/nixarr
- Nixarr options docs: https://nixarr.com/nixos-options/
- Nixarr declarative example: https://nixarr.com/wiki/examples/example-3
- Nixarr CHANGELOG: https://github.com/nix-media-server/nixarr/blob/main/CHANGELOG.md
- Recyclarr: https://github.com/recyclarr/recyclarr
- Jellarr: https://github.com/venkyr77/jellarr
- declarative-jellyfin (older alternative): https://github.com/Sveske-Juice/declarative-jellyfin
- Configarr (Recyclarr-superset, has its own NixOS module): https://github.com/raydak-labs/configarr
- Jellyseerr "seed settings.json" upstream FR: https://github.com/seerr-team/seerr/issues/2772
- Buildarr (abandoned, do not use): https://github.com/buildarr/buildarr
