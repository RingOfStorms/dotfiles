# Standalone per-host fleet-agent module (`ringofstorms.fleetAgent`).
#
# Can be imported on any host (container host, NAS, router, VPS, or laptop)
# without pulling in extra-container, podman, or /srv/containers.
#
# Serves read-only GET /status.json and GET /logs.json on `cfg.listen` (port
# 9101 on the host's overlay IP), polled by fleet-edge on h005.
#
# The HTTP daemon (`fleet-agent.service`) runs unprivileged (`DynamicUser =
# true`, `NoNewPrivileges = true`, `ProcSubset = "all"`). Privileged hardware
# and security snapshots (`smartctl -j -a -n standby`, `bcachefs fs usage`,
# and fail2ban SQLite/status) are collected by root companion timers into
# `/run/fleet-agent/*.json` (mode 0644), which `fleet-agent` reads on poll.
{
  config,
  lib,
  pkgs,
  fleet ? { },
  ...
}:
let
  cfg = config.ringofstorms.fleetAgent;
  stateDir = "/run/fleet-agent";
  fleetHosts = fleet.hosts or { };
  hostDef = fleetHosts.${config.networking.hostName} or { };
  defaultOverlayIp = hostDef.overlayIp or null;
  defaultPollers =
    lib.optional ((fleetHosts.h005.overlayIp or null) != null) fleetHosts.h005.overlayIp
    ++ [ "fd7a:115c:a1e0::3" ];

  smartScript = pkgs.writeShellScript "fleet-agent-smart" ''
    set -euo pipefail
    install -d -m 0755 ${stateDir}
    tmp="${stateDir}/smart.json.tmp.$$"
    now="$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Preserve previous reading for drives currently in standby so sleeping
    # spinning disks keep their last known attributes.
    prev="${stateDir}/smart.json"

    raw_entries=""
    sep=""
    for dev in $(${pkgs.util-linux}/bin/lsblk -d -n -o NAME,TYPE | ${pkgs.gawk}/bin/awk '$2 == "disk" && $1 !~ /^(loop|ram|zram|sr|fd)/ { print "/dev/" $1 }'); do
      [ -b "$dev" ] || continue
      out="$(${pkgs.smartmontools}/bin/smartctl -j -a -n standby "$dev" 2>/dev/null || true)"
      if [ -n "$out" ] && printf '%s' "$out" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
        # If smartctl reported standby (power_mode standby or message) and we have previous raw data, merge it
        if printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '(.messages // [] | any(.string | test("standby|sleep"; "i"))) and ((.model_name // "") == "")' >/dev/null 2>&1 && [ -s "$prev" ]; then
          old="$(${pkgs.jq}/bin/jq -c --arg d "$dev" '.raw[$d] // empty' "$prev" 2>/dev/null || true)"
          if [ -n "$old" ]; then
            out="$(printf '%s' "$old" | ${pkgs.jq}/bin/jq -c '. + {power_mode: "STANDBY"}')"
          fi
        fi
        compact="$(printf '%s' "$out" | ${pkgs.jq}/bin/jq -c .)"
        raw_entries="''${raw_entries}''${sep}\"''${dev}\":''${compact}"
        sep=","
      fi
    done

    printf '{"updatedAt":"%s","raw":{%s}}\n' "$now" "$raw_entries" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "${stateDir}/smart.json"
  '';

  bcachefsScript = pkgs.writeShellScript "fleet-agent-bcachefs" ''
    set -euo pipefail
    install -d -m 0755 ${stateDir}
    tmp="${stateDir}/bcachefs.json.tmp.$$"

    # Find one mountpoint per bcachefs filesystem
    pools_json="{}"
    while read -r dev mnt fstype _; do
      [ "$fstype" = "bcachefs" ] || continue
      usage="$(${pkgs.bcachefs-tools}/bin/bcachefs fs usage "$mnt" 2>/dev/null || true)"
      [ -n "$usage" ] || continue
      uuid="$(printf '%s\n' "$usage" | ${pkgs.gawk}/bin/awk '/^Filesystem:/ { print $2; exit }')"
      [ -n "$uuid" ] || continue
      pools_json="$(printf '%s' "$pools_json" | ${pkgs.jq}/bin/jq -c \
        --arg u "$uuid" --arg m "$mnt" --arg t "$usage" \
        '.[$u] = (.["$u"] // {uuid: $u, mount: $m, usageText: $t})')"
    done < /proc/mounts

    printf '{"pools":%s}\n' "$pools_json" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "${stateDir}/bcachefs.json"
  '';

  fail2banScript = pkgs.writeShellScript "fleet-agent-fail2ban" ''
    set -euo pipefail
    install -d -m 0755 ${stateDir}
    tmp="${stateDir}/fail2ban.json.tmp.$$"
    now="$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    db="/var/lib/fail2ban/fail2ban.sqlite3"

    jails_json="[]"
    bans_json="[]"

    # Query fail2ban-client for live jail counters + active banned IPs
    if ${pkgs.systemd}/bin/systemctl is-active --quiet fail2ban.service; then
      jails="$(${pkgs.fail2ban}/bin/fail2ban-client status 2>/dev/null | ${pkgs.gnused}/bin/sed -n 's/.*Jail list:[[:space:]]*//p' | ${pkgs.coreutils}/bin/tr ',' ' ')"
      for j in $jails; do
        st="$(${pkgs.fail2ban}/bin/fail2ban-client status "$j" 2>/dev/null || true)"
        [ -n "$st" ] || continue
        cur_f="$(printf '%s\n' "$st" | ${pkgs.gawk}/bin/awk -F: '/Currently failed:/ { gsub(/[^0-9]/, "", $2); print $2+0; exit }')"
        tot_f="$(printf '%s\n' "$st" | ${pkgs.gawk}/bin/awk -F: '/Total failed:/ { gsub(/[^0-9]/, "", $2); print $2+0; exit }')"
        cur_b="$(printf '%s\n' "$st" | ${pkgs.gawk}/bin/awk -F: '/Currently banned:/ { gsub(/[^0-9]/, "", $2); print $2+0; exit }')"
        tot_b="$(printf '%s\n' "$st" | ${pkgs.gawk}/bin/awk -F: '/Total banned:/ { gsub(/[^0-9]/, "", $2); print $2+0; exit }')"
        ips="$(printf '%s\n' "$st" | ${pkgs.gnused}/bin/sed -n 's/.*Banned IP list:[[:space:]]*//p')"
        ips_arr="$(printf '%s' "$ips" | ${pkgs.jq}/bin/jq -R 'split(" ") | map(select(length > 0))')"
        jails_json="$(printf '%s' "$jails_json" | ${pkgs.jq}/bin/jq -c \
          --arg name "$j" \
          --argjson cf "''${cur_f:-0}" \
          --argjson tf "''${tot_f:-0}" \
          --argjson cb "''${cur_b:-0}" \
          --argjson tb "''${tot_b:-0}" \
          --argjson ips "''${ips_arr:-[]}" \
          '. + [{name: $name, currentlyFailed: $cf, totalFailed: $tf, currentlyBanned: $cb, totalBanned: $tb, bannedIPs: $ips}]')"
      done
    fi

    # Read recent bans from SQLite using mode=ro with normal locking (never immutable=1 on a live DB)
    if [ -r "$db" ]; then
      bans_json="$(${pkgs.sqlite}/bin/sqlite3 -json "file:''${db}?mode=ro" \
        "SELECT jail, ip, strftime('%Y-%m-%dT%H:%M:%SZ', timeofban, 'unixepoch') AS bannedAt, bantime AS banSeconds, bancount AS failures, CASE WHEN (timeofban + bantime) > unixepoch() THEN 1 ELSE 0 END AS active FROM bips ORDER BY timeofban DESC LIMIT 50;" 2>/dev/null \
        | ${pkgs.jq}/bin/jq -c 'map(.active = (.active == 1))' 2>/dev/null || echo "[]")"
      [ -n "$bans_json" ] || bans_json="[]"
    fi

    ${pkgs.jq}/bin/jq -n -c \
      --arg u "$now" \
      --argjson j "$jails_json" \
      --argjson b "$bans_json" \
      '{updatedAt: $u, jails: $j, recentBans: $b}' > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "${stateDir}/fail2ban.json"
  '';
in
{
  options.ringofstorms.fleetAgent = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = defaultOverlayIp != null;
      description = "Run the read-only fleet-agent status, metrics, and log endpoint for fleet-edge.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "The `fleet` CLI/agent package.";
    };
    listen = lib.mkOption {
      type = lib.types.str;
      default = if defaultOverlayIp != null then "${defaultOverlayIp}:9101" else "";
      example = "100.64.0.13:9101";
      description = "ADDR:PORT to listen on, normally the host's overlay IP. Required when enabled (never a wildcard).";
    };
    allowedPollers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = if defaultOverlayIp != null then defaultPollers else [ ];
      example = [
        "100.64.0.3"
        "fd7a:115c:a1e0::3"
      ];
      description = "Source IPv4/IPv6 addresses allowed to query `listen` in the host firewall.";
    };
    mounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/data:Data" ];
      description = "Explicit mountpoints (optionally `mount:Label`) to include in filesystem telemetry.";
    };
    extraFilesystems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/data" ];
      description = "Additional mountpoints (optionally `mount:Label`) to include in filesystem telemetry (merged with `mounts`).";
    };
    extraUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nginx.service"
        "sshd.service"
        "fail2ban.service"
        "tailscaled.service"
      ];
      description = "Host systemd units to report status for and allow journald log queries against.";
    };
    smart.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the periodic root smartctl collector (`fleet-agent-smart.timer`, `-n standby`).";
    };
    bcachefs.enable = lib.mkOption {
      type = lib.types.bool;
      default =
        if builtins.isAttrs config.boot.supportedFilesystems then
          config.boot.supportedFilesystems.bcachefs or false
        else
          builtins.elem "bcachefs" config.boot.supportedFilesystems;
      description = "Run the periodic root `bcachefs fs usage` collector (`fleet-agent-bcachefs.timer`).";
    };
    fail2ban.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.fail2ban.enable;
      description = "Run the periodic root fail2ban collector (`fleet-agent-fail2ban.timer`).";
    };
  };

  config = lib.mkIf cfg.enable (
    let
      m = builtins.match "\\[?([0-9a-fA-F:.]+)]?:([0-9]+)" cfg.listen;
      listenPort = if m != null then builtins.elemAt m 1 else "9101";
      allMounts = cfg.mounts ++ cfg.extraFilesystems;
      mountFlags = lib.concatMapStringsSep " " (x: "--mount ${lib.escapeShellArg x}") allMounts;
      unitFlags = lib.concatMapStringsSep " " (x: "--unit ${lib.escapeShellArg x}") cfg.extraUnits;
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion =
              builtins.match "(\\[[0-9a-fA-F:]+]|[0-9.]+):[0-9]+" cfg.listen != null
              && !(lib.hasPrefix "0.0.0.0:" cfg.listen)
              && !(lib.hasPrefix "[::]:" cfg.listen);
            message = "ringofstorms.fleetAgent.listen must be an explicit IP:PORT (e.g. the overlay IP \"100.64.0.13:9101\"), not empty or a wildcard.";
          }
        ];

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0755 root root -"
        ];

        # Register listener for `cnt audit` (cli/internal/containers/routes.go).
        environment.etc."fleet-containers/host-listeners".text = lib.optionalString (m != null) ''
          tcp ${builtins.elemAt m 0} ${builtins.elemAt m 1} host (status endpoint)
        '';

        networking.firewall.extraInputRules = lib.concatMapStrings (
          poller:
          let
            fam = if lib.hasInfix ":" poller then "ip6" else "ip";
          in
          ''
            iifname "tailscale0" ${fam} saddr ${poller} tcp dport ${listenPort} accept comment "fleet-agent status endpoint"
          ''
        ) cfg.allowedPollers;

        systemd.services.fleet-agent = {
          description = "Read-only fleet-agent status, metrics, and log server (fleet-edge)";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "tailscaled.service"
          ];
          path = [ pkgs.systemd ];
          serviceConfig = {
            ExecStart = "${lib.getExe cfg.package} agent --listen ${cfg.listen} --host ${config.networking.hostName} --state-dir ${stateDir} ${mountFlags} ${unitFlags}";
            Restart = "always";
            RestartSec = 5;
            DynamicUser = true;
            # Allow reading host and nspawn guest journal files without root/CAP_SYS_ADMIN.
            SupplementaryGroups = [ "systemd-journal" ];
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            # ProtectProc=invisible hides other users' PIDs while ProcSubset=all
            # keeps /proc/stat, /proc/meminfo, /proc/diskstats, /proc/net/dev,
            # /proc/loadavg, /proc/uptime, and /proc/mounts readable.
            ProtectProc = "invisible";
            ProcSubset = "all";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged @resources"
            ];
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            UMask = "0077";
          };
        };
      }

      (lib.mkIf cfg.smart.enable {
        systemd.services.fleet-agent-smart = {
          description = "Collect SMART drive health snapshot for fleet-agent";
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = smartScript;
            TimeoutStartSec = "2min";
          };
        };
        systemd.timers.fleet-agent-smart = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "15min";
            AccuracySec = "30s";
          };
        };
      })

      (lib.mkIf cfg.bcachefs.enable {
        systemd.services.fleet-agent-bcachefs = {
          description = "Collect bcachefs pool usage snapshot for fleet-agent";
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = bcachefsScript;
            TimeoutStartSec = "1min";
          };
        };
        systemd.timers.fleet-agent-bcachefs = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "15s";
            OnUnitActiveSec = "2min";
            AccuracySec = "15s";
          };
        };
      })

      (lib.mkIf cfg.fail2ban.enable {
        systemd.services.fleet-agent-fail2ban = {
          description = "Collect fail2ban jail and ban snapshot for fleet-agent";
          after = [ "fail2ban.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = fail2banScript;
            TimeoutStartSec = "30s";
          };
        };
        systemd.timers.fleet-agent-fail2ban = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "20s";
            OnUnitActiveSec = "1min";
            AccuracySec = "10s";
          };
        };
      })
    ]
  );
}
