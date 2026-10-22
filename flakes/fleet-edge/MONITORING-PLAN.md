# Fleet Monitoring, `fleet-agent`, and `fleet-edge` Health Plan

Replaces `flakes/beszel` and `containers/beszel` with a native fleet health, metrics, and drill-down system built into `fleet-edge` (hub on `h005`) and `fleet-agent` (per-host read-only agent on `:9101`), while separating container management from host telemetry.

---

## 1. Architecture & Codebase Separation

Today, `containers/cli` builds a single `containers` binary (`package main`) where container orchestration (`deploy`, `move`, `expose`, `audit`) and the host status server (`status-server`) live side-by-side, and `hosts/containers-status.nix` sets `ringofstorms.containers.statusEndpoint`. Non-container hosts (`h004`, `h005`, `o002`, `juni`, `oren`, `gp3`, `i001`) do not import the containers host module.

### 1.1 CLI & Package Layout (`containers/cli` $\to$ `fleet`)
- **Binary name:** `fleet` (with `cnt` shell alias set to `fleet containers`).
- **Command tree:**
  - `fleet containers <subcmd> [args...]` — existing container management commands (`ls`, `status`, `watch`, `logs`, `deploy`, `start`, `stop`, `restart`, `online`, `attach`, `shell`, `backup`, `restore`, `move`, `destroy`, `routes`, `audit`, `port`, `expose`, `check-idmap`, `inventory`).
  - `fleet agent --listen ADDR [--host NAME] [--state-dir /run/fleet-agent] [--mount /data:Data ...]` — the per-host read-only HTTP agent (`:9101`).
- **Internal package boundaries (`containers/cli/`):**
  ```
  containers/cli/
    main.go                 # top-level `fleet` dispatcher (`containers` vs `agent`)
    internal/
      containers/           # all container CLI & SSH orchestration (deploy, move, expose, routes, privnet, audit)
      agent/                # fleet-agent HTTP server + collectors (zero SSH/orchestration code)
        server.go           # GET /status.json, GET /logs.json
        proc.go             # /proc/stat, /proc/meminfo, /proc/loadavg, /proc/uptime, /proc/diskstats, /proc/net/dev
        hwmon.go            # /sys/class/hwmon & /sys/class/thermal temperatures
        bcachefs.go         # /sys/fs/bcachefs/<uuid>/ sysfs accounting + bcachefs fs usage parser
        filesystems.go      # statfs + mount discovery + bcachefs enrichment
        units.go            # installed floating container units (/etc/systemd-mutable & gcroots) + host systemd units
        logs.go             # journalctl -u (host/podman units) and journalctl -M (nspawn guest journals)
        snapshots.go        # reads /run/fleet-agent/{smart,fail2ban,bcachefs}.json written by root timers
  ```

### 1.2 NixOS Module Separation
- **`containers.nixosModules.agent` (`ringofstorms.fleetAgent`)**:
  - Standalone NixOS module (`containers/agent-module.nix`) with **no** dependency on `extra-container`, podman, or `/srv/containers`.
  - Can be imported on **every** host in `hosts/fleet.nix` (`h001`, `h003`, `h004`, `h005`, `o002`, `lio`, `joe`, `i001`, and laptops `oren`, `juni`, `gp3`).
  - Replaces `hosts/containers-status.nix` with `hosts/fleet-agent.nix`.
  - Options:
    ```nix
    ringofstorms.fleetAgent = {
      enable = true;
      listen = "${overlayIp}:9101"; # or lanIp on LAN-only hosts like i001
      allowedPollers = [ fleet.hosts.h005.overlayIp "fd7a:115c:a1e0::3" ];
      filesystems = [ "/" "/persist" "/nix" ]; # auto-detects mounted bcachefs/ext4/zfs or explicit list
      extraUnits = [ "nginx.service" "sshd.service" "fail2ban.service" "nfs-server.service" ];
      smart.enable = true;      # enables fleet-agent-smart.timer (default true on bare-metal, false on VPS)
      fail2ban.enable = config.services.fail2ban.enable;
      bcachefs.enable = builtins.elem "bcachefs" config.boot.supportedFilesystems;
    };
    ```
  - Automatically adds the nftables input rule admitting `allowedPollers` to the configured `listen` port on `tailscale0` (and LAN interface for LAN-only hosts like `i001`).

---

## 2. First-Class `bcachefs` Support

Standard `statfs` (`df`) on a multi-device `bcachefs` pool with `replicas=2` (like `h004`'s `/data` pool with 4× 12 TB IronWolf + 1× 12 TB WD Red = ~60 TB raw) reports **raw device blocks**, which makes 1 GB of written user data look like 2 GB of capacity consumed and hides replication overhead, per-device allocation, bucket states, and compression ratios.

### 2.1 What We Collect for Every `bcachefs` Mount
`bcachefs` exposes rich live accounting in `/sys/fs/bcachefs/<uuid>/` and via `bcachefs fs usage -h <mount>` / `bcachefs show-super`:

1. **Pool-level accounting:**
   - `uuid`, `version` (e.g. `1.39`), `mountedPath` (`/`, `/data`, `/scratch`), `subvolumes` (`@root`, `@nix`, `@persist`, `@snapshots` — deduplicated by filesystem UUID so a single bcachefs root with 4 subvolume mounts isn't counted 4× as separate disks!).
   - **Raw Capacity vs. Usable Capacity:**
     - `rawTotalBytes`, `rawUsedBytes`, `rawFreeBytes`, `rawOnlineReservedBytes`
     - `dataReplicas` (effective replica factor, e.g. `2.0` on `/data`, `1.0` on single-SSD root)
     - `usableTotalBytes` ($\approx \text{rawTotal} / \text{replicas}$), `logicalUsedBytes` (actual user data bytes before replication), `effectiveFreeBytes` (how many logical bytes can actually be written at the current replica target).
   - **Data breakdown by type (from `accounting/` or `bcachefs fs usage`):**
     - `btreeBytes`, `userDataBytes`, `cachedBytes`, `parityBytes`, `reservedBytes`
     - `compressionRatio` / compressed vs uncompressed bytes (when compression is enabled)
   - **Health & errors:**
     - `degraded` boolean, `readErrors`, `writeErrors`, `checksumErrors` across devices.
2. **Per-device breakdown (`/sys/fs/bcachefs/<uuid>/dev-N/`):**
   - `label` / block device (`sda`, `sdb`, ...), `model` / `serial` (cross-linked with SMART data!), `state` (`rw`, `ro`, `evacuating`, `spare`), `durability`.
   - `capacityBytes`, `usedBytes`, `freeBytes`, `fragmentedBytes`.
   - Per-device IO error counters (`io_errors`).

### 2.2 Collection Mechanism
- `/sys/fs/bcachefs/<uuid>/` counters and device dirs are world-readable (`0444`) and can be read directly by `fleet-agent` on every poll (`BindReadOnlyPaths = [ "/sys/fs/bcachefs" ]`).
- For detailed replica/accounting tables that require `BCACHEFS_IOC_FS_USAGE` ioctl (`bcachefs fs usage <mount>`), a lightweight root companion timer (`fleet-agent-bcachefs.timer`, every 2 minutes) dumps structured output to `/run/fleet-agent/bcachefs.json`.
- **UI Presentation in `fleet-edge`:**
  - Shows **both** Usable (`21.4 TB / 25.1 TB usable · 2× replicas`) and Raw (`42.8 TB / 50.2 TB raw`) side-by-side on the storage bar so you never have to do mental math.
  - Subvolume mounts sharing the same bcachefs UUID (`@root`, `@nix`, `@persist`, `@snapshots`) are grouped under one pool card instead of 4 redundant bars.
  - Expanding the pool on `/hosts/h004` shows each member drive's allocation bar, state (`rw`), error counters, and linked SMART health (`temp`, `powerOnHours`, `reallocatedSectors`).

---

## 3. Drill-Down Collectors: SMART, Fail2ban, and Logs

`fleet-agent.service` stays unprivileged (`DynamicUser = true`, `NoNewPrivileges = true`, `ProtectProc = "invisible"`, `ProcSubset = "all"`). Anything needing root runs in a tiny oneshot systemd timer that writes JSON to `/run/fleet-agent/` (`RuntimeDirectory = "fleet-agent"`).

### 3.1 SMART Drive Health (`fleet-agent-smart.timer`, every 15m)
- Scans block devices (`lsblk -d -n -o NAME,TYPE,ROTA,MODEL,SERIAL`) and runs `smartctl -j -a -n standby /dev/<dev>`.
- `-n standby` ensures spinning HDDs in standby/spindown are never woken up by monitoring; their last known attributes are preserved with `"standby": true`.
- Extracts: `device`, `model`, `serial`, `protocol` (`ATA`/`NVMe`), `healthy` (SMART passed), `tempC`, `powerOnHours`, `reallocatedSectors`, `pendingSectors`, `uncorrectableErrors`, `nvmePercentageUsed`, `crcErrors`, `lastTestStatus`.

### 3.2 Fail2ban Status (`fleet-agent-fail2ban.timer`, every 1m when `services.fail2ban.enable`)
- Reads `/var/lib/fail2ban/fail2ban.sqlite3` in read-only mode with normal locking (`file:/var/lib/fail2ban/fail2ban.sqlite3?mode=ro` or via a consistent `.backup` snapshot, never `immutable=1` on a live DB) and/or `fail2ban-client status`.
- Exports active jails, `currentlyBanned` count, `totalBanned` count, and the list of active bans (`ip`, `jail`, `timeOfBan`, `banSecondsRemaining`, `failures`) plus recent historical bans (last 50) so you can inspect who got banned and when.

### 3.3 Live Logs Endpoint (`GET /logs.json`)
- As noted in `containers/cli/main.go:904–907`, floating services have two distinct log sources:
  1. **nspawn guests (`kind == "nixos"`):** application logs live inside the guest journal (`journalctl -M <svc>`), whereas `journalctl -u container@<svc>.service` only shows the outer nspawn supervisor!
  2. **podman guests (`kind == "podman"`) & host services:** logs live in the host journal (`journalctl -u fleet-<svc>.service`, `nginx.service`, `fail2ban.service`, `sshd.service`, etc.).
- **How `fleet-agent` serves both safely:**
  - `GET /logs.json?target=<name>&kind=<guest|unit>&lines=200&priority=<p>&grep=<q>`
  - `target` is validated against a strict regex (`^[a-zA-Z0-9_.-]+$`) and checked against an allowlist of installed container names + configured host `extraUnits`.
  - `fleet-agent.service` runs with `SupplementaryGroups = [ "systemd-journal" ]` and read-only bind mounts for `/var/log/journal`, `/run/log/journal`, and `/var/lib/nixos-containers/*/var/log/journal` (or uses `--directory=/var/lib/nixos-containers/<svc>/var/log/journal` / `/srv/containers/<svc>/nixos/var/log/journal`), allowing `journalctl -D <guest-journal-dir> -o json -n <N>` to read nspawn guest journals **without** `CAP_SYS_ADMIN` or entering the container namespace!

---

## 4. Offline & Intermittent Hosts (Laptops: `oren`, `juni`, `gp3`, etc.)

Unlike servers (`h001`, `h003`, `h004`, `h005`, `o002`), laptops and workstations (`oren`, `juni`, `gp3`, `lio`, `joe`, `i001`) power off or sleep regularly.

### 4.1 Host Role Classification in `hosts/fleet.nix`
Add an optional `role` (or `alwaysOn`) attribute in `hosts/fleet.nix`:
- `role = "server"` (`alwaysOn = true`): `h001`, `h003`, `h004`, `h005`, `o002`
- `role = "workstation"` / `"laptop"` (`alwaysOn = false`): `lio`, `joe`, `i001`, `oren`, `juni`, `gp3`

### 4.2 Polling & Last-Seen Persistence in `fleet-edge`
1. **Last-Known Snapshot Persistence in SQLite (`host_last_state` table):**
   - Every time a host responds to a poll, `fleet-edge` upserts its full latest `status.json` snapshot and `last_seen_at` timestamp into SQLite on `h005`.
   - When `oren` or `juni` is asleep (or even if `fleet-edge` itself restarts while `oren` is offline), `fleet-edge` still knows `oren`'s hardware specs, disk usage, bcachefs health, and SMART status from when it was last online ("Offline · last seen 4h ago").
2. **Visual Distinction (Offline vs. Down):**
   - `alwaysOn = true` host unreachable $\to$ **Red `DOWN` alert badge** at the top of `/hosts`.
   - `alwaysOn = false` host unreachable $\to$ **Muted/Neutral `SLEEP / OFFLINE` badge** (sorted into a "Workstations & Laptops" section below Always-On Servers, or collapsible), showing its last recorded disk/battery/system state and seamlessly resuming live sparklines the moment it wakes up on the tailnet.
3. **Chart Gap Handling:**
   - When rendering SVG time-series charts for laptops, time gaps $> 2\times$ the poll interval break the SVG `<path>` (`M ... L ...`) into separate segments rather than drawing a false diagonal line across a 12-hour sleep window.
4. **Fast Timeout / Non-Blocking Poll:**
   - Each host is polled in its own goroutine with a 3s timeout; an offline laptop never delays server polls.

---

## 5. Authentication: Zitadel OIDC + Plain API Keys (Matching `containers/sec`)

Right now `fleet-edge` has no built-in auth (`hosts/h005/fleet-edge.nix` serves plain HTTP on `100.64.0.3:80` to the tailnet). We will match the exact authentication model used by `secrets_manager` in `containers/sec/container.nix`:

```nix
zitadel = {
  issuer = "https://sso.joshuabell.xyz";
  projectId = "344379162166820867";
  claim = "flatRolesClaim";
  clientId = "<fleet-edge-client-id>";
  redirectUri = "https://fleet.joshuabell.xyz/auth/callback"; # or tailnet TLS vhost on h005
};
```

### 5.1 Dual Auth Middleware in `fleet-edge`
Every route on `fleet-edge` (except `GET /healthz`, `GET /auth/login`, and `GET /auth/callback`) passes through `authMiddleware`:

1. **Browser UI Login (Zitadel OIDC with PKCE):**
   - Public OIDC client (Authorization Code + PKCE, exact same flow as `sec` UI, no client secret needed on disk).
   - Discovers endpoints from `{issuer}/.well-known/openid-configuration` and verifies JWT signatures against `{issuer}/oauth/v2/keys` (JWKS) or userinfo/introspection.
   - Checks the Zitadel role claim (`flatRolesClaim` / `urn:zitadel:iam:org:project:{projectId}:roles`) for required role (e.g. `admin` or `fleet-viewer`).
   - Issues an `HttpOnly; Secure; SameSite=Lax` HMAC-signed session cookie (`fleet_session`) stored using a key managed by `sec-agent` on `h005`.
   - Unauthenticated browser requests (`Accept: text/html`) redirect automatically to `/auth/login` $\to$ Zitadel $\to$ `/auth/callback` $\to$ original URL.

2. **Plain API Key Auth (CLI, scripts, homepage widgets):**
   - Accepts `Authorization: Bearer <key>` or `X-API-Key: <key>`.
   - Configured via `--api-keys-file /run/secrets/fleet_edge_api_keys` (hydrated by `sec-agent` on `h005`; one `name:sha256_hex` or token per line, compared with `crypto/subtle.ConstantTimeCompare`).
   - Allows `fleet` CLI or scripts to query `GET /api/state.json`, `GET /api/hosts/{host}/history`, or future write endpoints without interactive OIDC.

3. **TLS on `h005`:**
   - `h005` already issues and holds the `*.joshuabell.xyz` wildcard cert (`hosts/h005/wildcard-cert.nix`)!
   - Serve `fleet-edge` over HTTPS at `https://fleet.joshuabell.xyz` (tailnet DNS record in `hosts/h005/dns-records.nix` $\to$ `100.64.0.3`, with `http://h005.net.joshuabell.xyz` redirecting to `https://fleet.joshuabell.xyz`).

---

## 6. Time-Series Storage, Rollups & Merging `h002` $\to$ `h004`

### 6.1 SQLite Schema (`/var/lib/fleet-edge/metrics.db`, WAL mode)
 persisted in `hosts/h005/impermanence.nix` (`/var/lib/fleet-edge`):
- **`host_samples`** (resolution: `30s` raw for 7d, `300s` 5m rollup for 90d, `3600s` 1h rollup for 5y+):
  - `host TEXT, ts INTEGER, step INTEGER` (`PRIMARY KEY (host, step, ts)`)
  - `cpu_pct REAL, load1 REAL, mem_used_bytes INTEGER, mem_total_bytes INTEGER, swap_used_bytes INTEGER`
  - `net_rx_bps INTEGER, net_tx_bps INTEGER, disk_read_bps INTEGER, disk_write_bps INTEGER, max_temp_c REAL`
- **`fs_samples`** (per-mount capacity + bcachefs logical/raw usage over time, rolled up to 5m / 1h):
  - `host TEXT, mount TEXT, ts INTEGER, step INTEGER`
  - `raw_used_bytes INTEGER, raw_total_bytes INTEGER, usable_used_bytes INTEGER, usable_total_bytes INTEGER`
- **`host_last_state`**:
  - `host TEXT PRIMARY KEY, last_seen_ts INTEGER, status_json TEXT` (keeps full latest SMART/bcachefs/fail2ban/system snapshot across reboots and while laptops sleep).
- **`host_events`**:
  - `id INTEGER PRIMARY KEY, host TEXT, ts INTEGER, kind TEXT, note TEXT` (e.g. `"replaced h002 -> h004"`, boot events, SMART warning transitions).

### 6.2 Host Lineage (`h002` $\to$ `h004`) & Beszel History Import
1. **Declarative Lineage (`replaces` in `hosts/fleet.nix`):**
   - In `hosts/fleet.nix`, add `replaces = [ "h002" ];` under `h004`.
   - `fleet-edge` reads `replaces` from `inventory.json`. Any historical data or incoming alias for `h002` is mapped to `h004` and an automatic event marker (`Replaced h002`) is recorded at the cutover timestamp.
2. **`fleet-edge import-beszel` Subcommand:**
   - Reads `/var/lib/beszel-hub/beszel_data/data.db` (`systems` and `system_stats` tables).
   - Maps `system_stats` JSON fields (`cpu`, `mp`, `mb`, `du`, `dr`, `dw`, `ns`, `nr`, `efs` extra filesystems like `/data__Data`) into `host_samples` and `fs_samples`.
   - Rewrites `h002` samples directly into `h004` (preserving exact timestamps) so `h004`'s 30d/1y CPU, memory, network, and `/data` storage growth charts are one continuous timeline from `h002` through `h004`.

---

## 7. `fleet-edge` UI Design (`/hosts` & `/hosts/{name}`)

Stays 100% server-rendered Go `html/template` + CSS + inline `<svg>` (zero JS framework):

1. **`GET /hosts` (Fleet Health Overview):**
   - **Section 1: Always-On Servers (`h001`, `h003`, `h004`, `h005`, `o002`)**
   - **Section 2: Workstations & Laptops (`lio`, `joe`, `i001`, `oren`, `juni`, `gp3`)**
   - Each host card shows:
     - Status pill (`ONLINE`, `SLEEP · 3h ago`, or `DOWN`), uptime, kernel/bcachefs version.
     - CPU %, Load, RAM %, Temp badge, and inline 24h SVG sparklines for CPU & Net throughput.
     - Storage bars (with bcachefs Usable vs Raw + replica badge, e.g. `/data: 21.4 / 25.1 TB (2×)`).
     - Health badges: SMART (`5/5 drives healthy` or warning icon), Fail2ban (`sshd: 2 banned`), Active Containers (`7/7 active`).
2. **`GET /hosts/{name}?range=1h|24h|7d|30d|1y` (Host Drill-Down):**
   - **Interactive Time-Series Charts (inline SVG):** CPU %, Memory, Network RX/TX, Disk Read/Write, Pool Storage Growth (with vertical dashed line marking the `h002` $\to$ `h004` hardware cutover).
   - **bcachefs Pools & Filesystems Panel:** Usable vs Raw capacity, replica factor, compression stats, per-device member usage bars, read/write/checksum error counts.
   - **SMART Drive Health Table:** Device, model, serial, temp, power-on hours, reallocated/pending sectors, NVMe wear %, standby status.
   - **Fail2ban Jails & Ban List:** Per-jail counts + table of currently banned IPs and recent ban history.
   - **Services & Live Log Viewer:** Every floating container and monitored host systemd unit on that machine, with buttons to view **App Logs** (`journalctl -M <guest>`) vs **Unit Supervisor Logs** (`journalctl -u ...`), filterable by line count and priority (`err`, `warning`, `info`).

---

## 8. Implementation Phases

| Phase | Scope | Verification |
| :--- | :--- | :--- |
| **Phase 1: CLI Rename & Split (`fleet` + `fleet-agent`)** | Split `containers/cli` into `internal/containers` and `internal/agent`. Build `fleet` binary (`cnt = "fleet containers"`, `fleet agent`). Create `containers/agent-module.nix` (`ringofstorms.fleetAgent`) and `hosts/fleet-agent.nix`. | `go test ./...`, `nix build ./containers`, verify `fleet containers ls` and `fleet agent` unit tests. |
| **Phase 2: Host Collectors (`bcachefs`, `/proc`, SMART, Fail2ban, Logs)** | Add `/proc` rate sampler, `/sys/class/hwmon`, `bcachefs` sysfs + `bcachefs fs usage` collector, SMART timer, fail2ban timer, and `/logs.json` (both `-M` guest journal dir and `-u` unit journal). | Unit tests with synthetic `/proc`, `/sys/fs/bcachefs`, `smartctl -j`, and `fail2ban` fixtures; deploy `fleet-agent` to one host and curl `:9101/status.json` & `:9101/logs.json`. |
| **Phase 3: `fleet-edge` Auth (Zitadel OIDC + API Keys)** | Add OIDC PKCE login (`/auth/login`, `/auth/callback`, JWKS validation matching `containers/sec`) + Bearer API key middleware in `flakes/fleet-edge`. Serve at `https://fleet.joshuabell.xyz` on `h005`. | Test unauthenticated redirect to Zitadel, role check, session cookie, and `curl -H "Authorization: Bearer ..."` against `/api/state.json`. |
| **Phase 4: SQLite Time-Series, Offline State & Beszel Import** | Add SQLite storage (`host_samples`, `fs_samples`, `host_last_state`), rollups, offline laptop handling (`role` in `fleet.nix`), `replaces = ["h002"]` on `h004`, and `fleet-edge import-beszel`. | Run `fleet-edge import-beszel` against a copy of `h001`'s Beszel `data.db`; verify `h002` + `h004` merge and rollup queries. |
| **Phase 5: `/hosts` & `/hosts/{name}` Drill-Down UI + Retire Beszel** | Build SVG charts, bcachefs pool breakdown, SMART table, fail2ban panel, and live log viewer in `fleet-edge`. Remove `flakes/beszel` from hosts and retire `containers/beszel`. | Verify UI in browser across server (`h004`) and sleeping laptop (`oren`), then remove Beszel agent/hub. |
