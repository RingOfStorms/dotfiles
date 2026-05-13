{
  pkgs,
  lib,
  constants,
  ...
}:
# Penpot (https://penpot.app) — self-hosted Figma alternative.
#
# Five containers running on a private podman network:
#   penpot-frontend   nginx + SPA, the only port published on the host
#   penpot-backend    clojure API
#   penpot-exporter   headless chromium for PDF/PNG export
#   penpot-mcp        MCP server (PENPOT_FLAGS includes enable-mcp)
#   penpot-postgres   postgres:15 (Penpot pins the major version)
#   penpot-valkey     valkey:8.1 (redis-compatible)
#
# Inter-container DNS uses the container names; that's how upstream's
# docker-compose works and we keep the same names so PENPOT_REDIS_URI /
# PENPOT_DATABASE_URI from the upstream docs work as-is.
#
# Exposure: tailscale-only. Only penpot-frontend's port is bound, and
# only to the overlay IP (100.64.0.13). No nginx vhost, no acme cert,
# no public domain. Reach it at http://h001.net.<domain>:8086 or
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
  #   enable-mcp                      — turns on the MCP integration
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
  systemd.tmpfiles.rules = [
    "d ${c.dataDir}            0755 root root -"
    "d ${c.dataDir}/postgres   0700 999  999  -"
    "d ${c.dataDir}/assets     0755 1000 1000 -"
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
      "penpot-frontend"
    ])
    (_: {
      after = commonAfter;
      requires = commonAfter;
    })
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

    penpot-mcp = {
      image = "penpotapp/mcp:${version}";
      autoStart = true;
      extraOptions = netOptsFor "penpot-mcp";
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

  # Open the frontend port on tailscale only (matches the bind above).
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
}
