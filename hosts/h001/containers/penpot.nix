{
  pkgs,
  lib,
  constants,
  ...
}:
# Penpot (https://penpot.app) — self-hosted Figma alternative.
#
# Seven containers running on a private podman network:
#   penpot-frontend   nginx + SPA. Published on the host.
#   penpot-backend    clojure API.
#   penpot-exporter   headless chromium for PDF/PNG export.
#   penpot-postgres   postgres:15 (Penpot pins the major version).
#   penpot-valkey     valkey:8.1 (redis-compatible).
#   penpot-mcp        Node MCP *server* (penpotapp/mcp image, running
#                     in `--multi-user` mode — image default). Two
#                     ports published on the host:
#                       4401  HTTP — MCP transport endpoint that AI
#                             clients (opencode, Claude Code, …)
#                             connect to.
#                       4402  WebSocket — channel between the loaded
#                             plugin (in the browser) and the server.
#                     Auth in multi-user mode is via a `userToken`
#                     query parameter that, per upstream docs, is
#                     currently hard-coded in the plugin source code
#                     for testing. Tailnet-only exposure mitigates this.
#                     File-system tools (import/export) are disabled
#                     in multi-user mode.
#   penpot-mcp-plugin Node sidecar that builds + serves the *Penpot
#                     MCP Plugin* (the browser-side half) on port 4400.
#                     The penpotapp/mcp image only ships the server;
#                     the plugin is a separate Vite-built app from the
#                     same repo (penpot/penpot-mcp, pinned commit in
#                     constants.services.penpot.mcpPluginRev). On first
#                     start it git-clones, npm-installs, and builds;
#                     subsequent starts just rerun `npm run dev` and
#                     watch the existing checkout (cached in dataDir).
#                     Vite bakes PENPOT_MCP_SERVER_ADDRESS into the
#                     plugin at *build* time — bumping the IP requires
#                     a rebuild (delete the cache dir).
#
# Inter-container DNS uses the container names; that's how upstream's
# docker-compose works and we keep the same names so PENPOT_REDIS_URI /
# PENPOT_DATABASE_URI from the upstream docs work as-is.
#
# Exposure: tailscale-only. Frontend (8086) and the three MCP ports
# (4400/4401/4402) are bound to the overlay IP (100.64.0.13). No nginx
# vhost, no acme cert, no public domain. Reach the UI at
# http://100.64.0.13:8086 over Tailscale.
#
# Secrets: PENPOT_SECRET_KEY is generated on first boot by the
# penpot-secret-key.service oneshot (random 64-byte urlsafe token,
# stored at ${dataDir}/secret-key.env, mode 0600 root) and loaded
# into backend + exporter via systemd EnvironmentFile=. The secret
# never enters the nix store.
let
  c = constants.services.penpot;
  hostIp = constants.host.overlayIp;

  version = "2.15";
  network = "penpot";

  # Shared flag set. Mirrors upstream defaults minus registration:
  #   disable-registration            — admin-only, create users via manage.py
  #   disable-email-verification      — no SMTP wired up
  #   disable-secure-session-cookies  — required: we serve plain HTTP on
  #                                     the tailnet, no TLS in front
  #   enable-prepl-server             — required by manage.py inside backend
  #   enable-mcp                      — turns on the in-product MCP UI
  #                                     affordances that pair with the
  #                                     penpot-mcp container.
  penpotFlags =
    "disable-registration disable-email-verification "
    + "enable-prepl-server enable-mcp "
    + "disable-secure-session-cookies";

  # Port the frontend's nginx listens on inside the container.
  frontendContainerPort = 8080;

  publicUri = "http://${hostIp}:${toString c.port}";

  # `KEY=VALUE\n`. Passed to backend/exporter via `podman run
  # --env-file=...` so PENPOT_SECRET_KEY arrives as a real env variable
  # inside the container without touching the nix store.
  #
  # NOTE: do NOT use systemd EnvironmentFile= for this — that loads the
  # variable into the *podman process* environment, but `podman run`
  # does not forward arbitrary host env to the container; only flags
  # like `-e KEY` (forward by name) or `--env-file` (read directly)
  # cross the boundary.
  secretKeyEnvFile = "${c.dataDir}/secret-key.env";

  # Per-container podman opts: join the shared user-defined network and
  # publish the container's own name as a DNS alias inside it.
  #
  # Why the explicit alias: NixOS's virtualisation.oci-containers sets
  # --name=<key> but does NOT register that name as a network alias on
  # user-defined podman networks. Without an alias, podman's built-in
  # DNS (aardvark) only resolves the random short container ID, so
  # `penpot-frontend`'s nginx fails with `host not found in upstream
  # "penpot-backend"` and crashes on startup. (Same for the backend
  # trying to reach `penpot-postgres` / `penpot-valkey`.)
  netOptsFor = name: [
    "--network=${network}"
    "--network-alias=${name}"
  ];

  # Wrapper so each container waits for the secret-key + network.
  commonAfter = [
    "penpot-network.service"
    "penpot-secret-key.service"
  ];
in
{
  # Data layout under /var/lib/penpot:
  #   postgres/         postgres:15 PGDATA  (uid 999, postgres image)
  #   assets/           backend uploads     (uid 1000, penpot image)
  #   secret-key.env    PENPOT_SECRET_KEY   (root:root 0600)
  #   mcp-plugin/       upstream penpot-mcp checkout + node_modules +
  #                     dist (root, the node:slim image runs as uid 0)
  systemd.tmpfiles.rules = [
    "d ${c.dataDir}             0755 root root -"
    "d ${c.dataDir}/postgres    0700 999  999  -"
    "d ${c.dataDir}/assets      0755 1000 1000 -"
    "d ${c.dataDir}/mcp-plugin  0755 root root -"
  ];

  # Trust the podman bridge for the `penpot` network on the host
  # firewall. Without this, NixOS's default-deny firewall drops
  # forwarded packets between sibling containers (postgres/valkey/
  # backend/exporter/frontend), and the backend's Hikari pool times
  # out trying to reach `penpot-postgres` on port 5432.
  #
  # We pin the bridge interface name (--opt isolate=true … bridge name)
  # via `podman network create --interface-name=...` below so this
  # match is stable across reboots / network re-creates.
  networking.firewall.trustedInterfaces = [ network ];

  systemd.services = {
    # One-shot: create the shared podman network if missing. Idempotent.
    # --interface-name pins the host-side bridge to the same name as
    # the network so the firewall trust above works.
    penpot-network = {
      description = "Create podman network for Penpot";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "podman.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        if ! ${pkgs.podman}/bin/podman network exists ${network}; then
          ${pkgs.podman}/bin/podman network create \
            --interface-name=${network} \
            ${network}
        fi
      '';
    };

    # One-shot: generate PENPOT_SECRET_KEY on first boot.
    # Penpot recommends a 512-bit base64url token; python's
    # `secrets.token_urlsafe(64)` is exactly that. Written as a
    # KEY=VALUE file and loaded into backend + exporter via
    # `podman run --env-file=...` (see container extraOptions).
    penpot-secret-key = {
      description = "Generate Penpot PENPOT_SECRET_KEY on first boot";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        umask 077
        if [ ! -s ${secretKeyEnvFile} ]; then
          key=$(${pkgs.python3}/bin/python3 -c \
            'import secrets; print(secrets.token_urlsafe(64), end="")')
          printf 'PENPOT_SECRET_KEY=%s\n' "$key" > ${secretKeyEnvFile}
          chmod 0600 ${secretKeyEnvFile}
        fi
      '';
    };
  }
  # Every podman-penpot-* unit waits for the network + secret-key oneshots.
  // lib.genAttrs
    (map (n: "podman-${n}") [
      "penpot-postgres"
      "penpot-valkey"
      "penpot-backend"
      "penpot-exporter"
      "penpot-mcp"
      "penpot-mcp-plugin"
      "penpot-frontend"
    ])
    (_: {
      after = commonAfter;
      requires = commonAfter;
    })
  // {
    # First-boot of penpot-mcp-plugin pays a full git clone +
    # npm-install + vite build, which can easily exceed the default
    # systemd start timeout (~90s on a slow disk). Give it 10 min.
    podman-penpot-mcp-plugin.serviceConfig.TimeoutStartSec = lib.mkForce "10min";
  }
  ;

  virtualisation.oci-containers.containers = {
    penpot-postgres = {
      image = "postgres:15";
      autoStart = true;
      extraOptions = netOptsFor "penpot-postgres" ++ [
        # Penpot's compose sends SIGINT for clean postgres shutdown.
        "--stop-signal=SIGINT"
      ];
      volumes = [
        "${c.dataDir}/postgres:/var/lib/postgresql/data"
      ];
      environment = {
        POSTGRES_INITDB_ARGS = "--data-checksums";
        POSTGRES_DB = "penpot";
        POSTGRES_USER = "penpot";
        # Local-only on a private podman network. Penpot's own compose
        # ships the same plaintext default; rotating this would require
        # also rotating the value baked into PENPOT_DATABASE_PASSWORD.
        POSTGRES_PASSWORD = "penpot";
      };
    };

    penpot-valkey = {
      image = "valkey/valkey:8.1";
      autoStart = true;
      extraOptions = netOptsFor "penpot-valkey";
      cmd = [
        "valkey-server"
        "--maxmemory" "128mb"
        "--maxmemory-policy" "volatile-lfu"
      ];
    };

    penpot-backend = {
      image = "penpotapp/backend:${version}";
      autoStart = true;
      extraOptions = netOptsFor "penpot-backend" ++ [
        # PENPOT_SECRET_KEY is loaded from a file at container start —
        # never enters the nix store. See penpot-secret-key.service.
        "--env-file=${secretKeyEnvFile}"
      ];
      dependsOn = [ "penpot-postgres" "penpot-valkey" ];
      volumes = [
        "${c.dataDir}/assets:/opt/data/assets"
      ];
      environment = {
        PENPOT_FLAGS = penpotFlags;
        PENPOT_PUBLIC_URI = publicUri;
        PENPOT_HTTP_SERVER_MAX_BODY_SIZE = "367001600";
        PENPOT_HTTP_SERVER_MAX_MULTIPART_BODY_SIZE = "367001600";

        PENPOT_DATABASE_URI = "postgresql://penpot-postgres/penpot";
        PENPOT_DATABASE_USERNAME = "penpot";
        PENPOT_DATABASE_PASSWORD = "penpot";

        PENPOT_REDIS_URI = "redis://penpot-valkey/0";

        PENPOT_OBJECTS_STORAGE_BACKEND = "fs";
        PENPOT_OBJECTS_STORAGE_FS_DIRECTORY = "/opt/data/assets";

        # Off — anonymous usage telemetry.
        PENPOT_TELEMETRY_ENABLED = "false";
      };
    };

    penpot-exporter = {
      image = "penpotapp/exporter:${version}";
      autoStart = true;
      extraOptions = netOptsFor "penpot-exporter" ++ [
        "--env-file=${secretKeyEnvFile}"
      ];
      dependsOn = [ "penpot-valkey" ];
      environment = {
        # Internal URI — exporter talks to the frontend container by name.
        PENPOT_PUBLIC_URI = "http://penpot-frontend:8080";
        PENPOT_REDIS_URI = "redis://penpot-valkey/0";
      };
    };

    # MCP server proper (penpotapp/mcp). Image default CMD is
    # `node index.js --multi-user`; we don't override it.
    #
    # Two ports published on the tailscale IP:
    #   4401  HTTP MCP transport   (AI clients connect here)
    #   4402  WebSocket            (in-browser plugin connects here)
    # The plugin asset port (4400) is served by penpot-mcp-plugin —
    # the upstream image, despite a name implying otherwise, ships
    # only the server, not the browser plugin.
    penpot-mcp = {
      image = "penpotapp/mcp:${version}";
      autoStart = true;
      extraOptions = netOptsFor "penpot-mcp";
      ports = [
        "${hostIp}:${toString c.mcpServerPort}:${toString c.mcpServerPort}"
        "${hostIp}:${toString c.mcpWebsocketPort}:${toString c.mcpWebsocketPort}"
      ];
      environment = {
        PENPOT_MCP_SERVER_LISTEN_ADDRESS = "0.0.0.0";
        PENPOT_MCP_SERVER_PORT = toString c.mcpServerPort;
        PENPOT_MCP_WEBSOCKET_PORT = toString c.mcpWebsocketPort;

        # The address the plugin (in the browser) uses to dial the
        # WebSocket back to this server. Must be reachable from the
        # browser, so we use the tailscale IP.
        PENPOT_MCP_SERVER_ADDRESS = hostIp;

        # Multi-user (image default CMD) requires this. Belt-and-
        # suspenders since the env var name is independent of the CLI
        # flag in some upstream versions.
        PENPOT_MCP_REMOTE_MODE = "true";
      };
    };

    # Plugin sidecar: builds the browser-side plugin from upstream
    # source and serves it on port 4400. The penpotapp/mcp image
    # doesn't ship the plugin, so we build it ourselves from
    # github.com/penpot/penpot-mcp at a pinned commit.
    #
    # Build flow inside the container:
    #   1. If /workspace/.git/HEAD doesn't match the pinned SHA, do a
    #      fresh shallow clone + npm-install + multi-user build.
    #   2. Run `npm run dev:multi-user` (under penpot-plugin) which
    #      starts vite-live-preview on port 4400.
    #
    # Vite bakes the WebSocket URL into the bundle at build time using
    # PENPOT_MCP_SERVER_ADDRESS / PENPOT_MCP_WEBSOCKET_PORT, so those
    # must match what penpot-mcp announces (we use the tailscale IP).
    #
    # The /workspace bind-mount caches node_modules and dist/ across
    # restarts, so subsequent boots only pay the npm-run-dev startup
    # cost (a few seconds), not the full 1-2 minute build.
    penpot-mcp-plugin = {
      # Full bookworm image (not -slim) so git is preinstalled; saves
      # an apt-get dance on every container restart.
      image = "node:22-bookworm";
      autoStart = true;
      extraOptions = netOptsFor "penpot-mcp-plugin";
      dependsOn = [ "penpot-mcp" ];
      ports = [
        "${hostIp}:${toString c.mcpPluginPort}:${toString c.mcpPluginPort}"
      ];
      volumes = [
        "${c.dataDir}/mcp-plugin:/workspace"
      ];
      environment = {
        # Build-time inputs (Vite `define` reads these).
        PENPOT_MCP_SERVER_ADDRESS = hostIp;
        PENPOT_MCP_WEBSOCKET_PORT = toString c.mcpWebsocketPort;
        # vite preview's allowedHosts gate; comma-separated. We pass
        # the host IP so requests with Host: 100.64.0.13:4400 aren't
        # rejected. (vite-live-preview is more permissive, but no harm
        # in being explicit.)
        PENPOT_MCP_PLUGIN_SERVER_LISTEN_ADDRESS = hostIp;
        PINNED_REV = c.mcpPluginRev;
      };
      cmd = [
        "bash" "-eu" "-c"
        ''
          cd /workspace

          current_rev=""
          if [ -d .git ]; then
            current_rev="$(git rev-parse HEAD 2>/dev/null || true)"
          fi

          if [ "$current_rev" != "$PINNED_REV" ]; then
            echo "[penpot-mcp-plugin] (re)cloning at $PINNED_REV (had: $current_rev)"
            shopt -s dotglob
            rm -rf /workspace/* /workspace/.[!.]* 2>/dev/null || true
            git clone https://github.com/penpot/penpot-mcp.git .
            git checkout "$PINNED_REV"
          else
            echo "[penpot-mcp-plugin] git cache hit at $PINNED_REV"
          fi

          # Don't trust the upstream npm scripts (`install:all` /
          # `build:all-multi-user`) — they wrap everything in
          # `concurrently` without `--kill-others-on-fail`, so a
          # failed install in one subpackage is silently ignored
          # and we end up with no node_modules. Run each step
          # directly with `set -e` so failures surface.
          #
          # `npm install` is idempotent and re-uses an existing
          # node_modules (~3s on cache hit), so we run it on every
          # boot to self-heal if anything is missing.
          for sub in common mcp-server penpot-plugin; do
            if [ ! -d "$sub/node_modules" ]; then
              echo "[penpot-mcp-plugin] npm install ($sub)"
              ( cd "$sub" && npm install --no-audit --no-fund )
            fi
          done

          # Build common first (penpot-plugin depends on it via file:..)
          ( cd common         && npm run build )

          # Patch vite.config.ts to bind the preview server to 0.0.0.0.
          # Upstream's `preview` block sets port + allowedHosts but
          # never host, so vite-live-preview defaults to 127.0.0.1 —
          # which is unreachable from outside the container, even with
          # `podman run -p ...`. Idempotent: only adds the line once.
          if ! grep -q 'host: "0.0.0.0"' penpot-plugin/vite.config.ts; then
            echo "[penpot-mcp-plugin] patching vite.config.ts to bind 0.0.0.0"
            sed -i 's/port: 4400,/host: "0.0.0.0", port: 4400,/' \
              penpot-plugin/vite.config.ts
          fi

          # Build the plugin in multi-user mode if dist/ is missing.
          # Otherwise vite build --watch will rebuild on next start anyway.
          if [ ! -f penpot-plugin/dist/manifest.json ]; then
            echo "[penpot-mcp-plugin] vite production build (multi-user)"
            ( cd penpot-plugin && npm run build:multi-user )
          fi

          # Hand off to vite-live-preview, which serves dist/ on :4400
          # and rebuilds on source changes.
          cd penpot-plugin
          exec npm run dev:multi-user
        ''
      ];
    };

    penpot-frontend = {
      image = "penpotapp/frontend:${version}";
      autoStart = true;
      extraOptions = netOptsFor "penpot-frontend";
      dependsOn = [ "penpot-backend" "penpot-exporter" ];
      # Bind ONLY to the tailscale overlay IP. Not on lan, not on
      # localhost, not on 0.0.0.0.
      ports = [
        "${hostIp}:${toString c.port}:${toString frontendContainerPort}"
      ];
      volumes = [
        "${c.dataDir}/assets:/opt/data/assets"
      ];
      environment = {
        PENPOT_FLAGS = penpotFlags;
        PENPOT_PUBLIC_URI = publicUri;
        PENPOT_HTTP_SERVER_MAX_BODY_SIZE = "367001600";
        PENPOT_HTTP_SERVER_MAX_MULTIPART_BODY_SIZE = "367001600";
      };
    };
  };

  # Open the frontend + MCP ports on tailscale only (matches the host
  # binds — frontend on c.port, penpot-mcp on the three MCP ports).
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    c.port
    c.mcpPluginPort
    c.mcpServerPort
    c.mcpWebsocketPort
  ];
}
