# Host side of the floating-services setup. Import it once per host:
#   inputs.containers.nixosModules.default
#
# After one rebuild with this module, the host can run any app in
# containers/<app>/ without another rebuild:
#   - extra-container installs nspawn units into /etc/systemd-mutable/system
#   - podman services install the same way (see lib.nix mkPodmanService)
#   - nginx includes /var/lib/fleet-containers/nginx/*.conf (written by `containers`)
#   - ports listed in /var/lib/fleet-containers/ports/<name> are opened in the firewall
#     (added to the nixos-fw `temp-ports` set and re-applied whenever the
#     firewall is reloaded)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ringofstorms.containers;
  stateDir = "/var/lib/fleet-containers";
  holdDir = "/run/fleet-containers/hold";
  mutable = "/etc/systemd-mutable/system";
  # nginx allow list for nginx.acl (ROUTING-PLAN §2.1), deny-by-default.
  aclText =
    cidrs:
    lib.concatMapStrings (c: "allow ${c};\n") (
      cidrs
      ++ lib.optionals cfg.nginx.acl.loopback [
        "127.0.0.1"
        "::1"
      ]
    )
    + "deny all;\n";
  guardScript =
    name: g:
    pkgs.writeShellScript "fleet-guard-${name}" ''
      set -u
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.systemd
          pkgs.util-linux
        ]
      }
      # Each check runs in its own child, SIGKILLed after 12 s: on a hard NFS
      # mount a stuck stat ignores SIGTERM, and a guard that hangs would
      # report healthy forever.
      # The sentinel goes first: opening a path below an autofs mount point
      # triggers the mount, while statfs on the mount point itself does not
      # (before the mount it reports the parent fs, e.g. ext4).
      probe() {
        ${lib.concatMapStrings (m: ''
          timeout -k 2 10 test -e ${lib.escapeShellArg m.sentinel} || { echo "guard ${name}: sentinel ${m.sentinel} missing"; return 1; }
          t=$(timeout -k 2 10 stat -f -c %T ${lib.escapeShellArg m.path}) || { echo "guard ${name}: ${m.path} not reachable"; return 1; }
          [ "$t" = ${lib.escapeShellArg m.fsType} ] || { echo "guard ${name}: ${m.path} is $t, not ${m.fsType}"; return 1; }
        '') g.mounts}
      }
      # Start what should run: installed, boot link present (`containers
      # stop` removes it), not held (`containers stop/backup/move`).
      start_wanted() {
        ${lib.concatStrings (
          lib.mapAttrsToList (svc: unit: ''
            # Check + enqueue under the lock `containers` takes to write the
            # hold, so a stop/backup can't slip in between (its stop job,
            # queued later, supersedes this start).
            (
              flock 9
              if [ -e ${mutable}/${unit} ] && ! [ -e ${holdDir}/${svc} ] \
                && ls ${mutable}/*.wants/${unit} >/dev/null 2>&1 \
                && ! systemctl is-active -q ${unit}; then
                echo "guard ${name}: starting ${unit}"
                systemctl start --no-block ${unit}
              fi
            ) 9>${holdDir}/${svc}.lock
          '') g.units
        )}
      }
      probe || exit 1
      systemd-notify --ready --status="storage ok"
      while :; do
        systemd-notify WATCHDOG=1
        start_wanted
        sleep ${toString g.interval}
        probe || exit 1
      done
    '';
  # Ports file lines (written by `containers deploy`):
  #   <tcp|udp> <port>                    open on every interface (temp-ports)
  #   <tcp|udp> <port> dnat <guest ipv4>  private-network route: DNAT host
  #                                       port -> guest (fleet-net-nat @routes)
  #   <tcp|udp> <port> dnat <guest ipv4> <host ipv4>   same, only for that
  #                                       destination (tailnet routes: overlay IP,
  #                                       fleet-net-nat @routes_at)
  #   <tcp|udp> <port> dnat <guest ipv4> <host ipv4> <src ipv4>   same, only
  #                                       from that source (route allow, @routes_from)
  #   guest <ve-iface>                    net.private guest (isolated, fleet-net @guests)
  #   noinet <ve-iface>                   private guest with internet = false
  #   allow <ve-iface> <ipv4> <tcp|udp> <port>   net.uses / net.egress exception
  # @routes, @routes_at, @routes_from, @guests, @noinet and @egress are flushed and refilled on every
  # run, so a redeploy or a removed ports file drops stale entries.
  applyPorts = pkgs.writeShellScript "fleet-containers-apply-ports" ''
    set -u
    nft=${pkgs.nftables}/bin/nft
    shopt -s nullglob
    fleetnet=0
    if $nft list table ip fleet-net-nat >/dev/null 2>&1; then
      fleetnet=1
      $nft flush map ip fleet-net-nat routes
      $nft flush map ip fleet-net-nat routes_at
      $nft flush map ip fleet-net-nat routes_from
      $nft flush set ip fleet-net-nat uses
      $nft flush set inet fleet-net guests
      $nft flush set inet fleet-net noinet
      $nft flush set inet fleet-net egress
    fi
    for f in ${stateDir}/ports/*; do
      while read -r proto port mode ip rest; do
        case "$proto" in
          guest|noinet|allow)
            case "$port" in ve-*) ;; *) continue ;; esac
            if [ "$fleetnet" != 1 ]; then
              echo "containers: $f has '$proto' but privateNetwork is off on this host" >&2
              continue
            fi
            case "$proto" in
              guest) set=guests; el="\"$port\"" ;;
              noinet) set=noinet; el="\"$port\"" ;;
              allow)
                case "$mode" in *[!0-9.]*|"") continue ;; esac
                case "$ip" in tcp|udp) ;; *) continue ;; esac
                case "''${rest:-}" in ""|*[!0-9]*) continue ;; esac
                set=egress; el="\"$port\" . $mode . $ip . $rest" ;;
            esac
            if [ "$proto" = allow ]; then
              $nft add element ip fleet-net-nat uses "{ $el }" \
                || echo "containers: could not add $el to nat @uses (from $f)" >&2
            fi
            $nft add element inet fleet-net $set "{ $el }" \
              || echo "containers: could not add $el to @$set (from $f)" >&2
            continue
            ;;
        esac
        case "$proto" in tcp|udp) ;; *) continue ;; esac
        case "$port" in ""|*[!0-9]*) continue ;; esac
        if [ "''${mode:-}" = dnat ]; then
          case "$ip" in 10.233.*) ;; *) echo "containers: bad dnat target '$ip' (from $f)" >&2; continue ;; esac
          # A DNAT port is never a plain host port: drop a leftover temp-ports
          # element from before the service went private (no flush: the set
          # is shared, e.g. with agnos).
          $nft delete element inet nixos-fw temp-ports "{ $proto . $port }" 2>/dev/null || true
          if [ "$fleetnet" = 1 ]; then
            if [ -n "''${rest:-}" ]; then
              read -r at src extra <<< "$rest"
              case "$at" in ""|*[!0-9.]*) echo "containers: bad dnat address '$at' (from $f)" >&2; continue ;; esac
              if [ -n "''${src:-}" ]; then
                case "$src" in *[!0-9.]*) echo "containers: bad dnat source '$src' (from $f)" >&2; continue ;; esac
                $nft add element ip fleet-net-nat routes_from "{ $src . $at . $proto . $port : $ip }" \
                  || echo "containers: could not DNAT $src -> $at $proto/$port to $ip (from $f)" >&2
                continue
              fi
              rest=$at
              $nft add element ip fleet-net-nat routes_at "{ $rest . $proto . $port : $ip }" \
                || echo "containers: could not DNAT $rest $proto/$port to $ip (from $f)" >&2
              continue
            fi
            $nft add element ip fleet-net-nat routes "{ $proto . $port : $ip }" \
              || echo "containers: could not DNAT $proto/$port to $ip (from $f)" >&2
          else
            echo "containers: $f wants DNAT but privateNetwork is off on this host" >&2
          fi
          continue
        fi
        $nft add element inet nixos-fw temp-ports "{ $proto . $port }" \
          || echo "containers: could not open $proto/$port (from $f)" >&2
      done < "$f"
    done
    # A firewall (re)start flushes the whole ruleset, including podman's
    # netavark table, which kills published ports. Re-create it.
    if [ -x /run/current-system/sw/bin/podman ]; then
      /run/current-system/sw/bin/podman network reload --all >/dev/null \
        || echo "containers: podman network reload failed" >&2
    fi
  '';
  guardUnits = lib.mkMerge (
    lib.mapAttrsToList (name: g: {
      services."fleet-guard-${name}" = {
        description = "Storage guard ${name}: runs ${lib.concatStringsSep ", " (lib.attrNames g.units)} only while its mounts are live";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "remote-fs.target"
        ];
        startLimitIntervalSec = 0;
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "all";
          ExecStart = guardScript name g;
          Restart = "always";
          RestartSec = 60;
          # A probe round is bounded (12 s per check); the loop must ping
          # within this or systemd kills the guard, which stops the units.
          WatchdogSec = g.interval * 2 + 36 * builtins.length g.mounts + 30;
          TimeoutStartSec = 36 * builtins.length g.mounts + 30;
        };
      };
      # Drop-ins (container@<name> itself is installed at runtime).
      units = lib.mapAttrs' (
        _: unit:
        lib.nameValuePair unit {
          overrideStrategy = "asDropin";
          text = ''
            [Unit]
            BindsTo=fleet-guard-${name}.service
            After=fleet-guard-${name}.service
          '';
        }
      ) g.units;
    }) cfg.guards
  );

  # Per-host restic backup of every floating service here (ROUTING-PLAN §9.1).
  # Each service is its own snapshot tagged `fleet` + `svc:<name>`, so parent
  # selection and retention group by tags only, not host: after `cnt move`
  # the new host continues the same service history (the snapshot's
  # hostname field records where it ran).
  bcfg = cfg.backup;
  fleetServices = builtins.listToAttrs (
    map (s: lib.nameValuePair s.name s) ((import ./lib.nix).allServices ./.)
  );
  hookCase =
    s:
    let
      run =
        if s.kind == "podman" then
          "${pkgs.podman}/bin/podman exec ${s.name} sh -c ${lib.escapeShellArg s.backupHook}"
        else
          "${pkgs.nixos-container}/bin/nixos-container run ${s.name} -- bash -lc ${lib.escapeShellArg s.backupHook}";
    in
    "    ${s.name}) ${run} ;;\n";
  withHook = builtins.filter (s: (s.backupHook or null) != null) (builtins.attrValues fleetServices);
  # `fleet-backup` backs up every installed service, then prunes.
  # `fleet-backup <svc>...` (fleet-backup-svc@<svc>.service, used by `cnt
  # move`) backs up only those, even if their unit is not running, and does
  # not prune. On success each service gets a stamp in ${backupStampDir}/<svc>:
  #   time=<RFC3339 UTC> snapshot=<restic id> host=<hostname>
  # read by `cnt status-server` (backup age on fleet-edge) and `cnt move`.
  backupStampDir = "${stateDir}/backup-last";
  backupScript = pkgs.writeShellScript "fleet-backup" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.systemd
        pkgs.sqlite
        pkgs.restic
        pkgs.util-linux
      ]
    }
    root=/srv/containers
    staging=/var/lib/fleet-backup/staging
    stamps=${backupStampDir}
    host=$(${pkgs.hostname}/bin/hostname)
    install -d -m755 "$stamps" "$staging"
    runHook() {
      case "$1" in
    ${lib.concatMapStrings hookCase withHook}    *) return 0 ;;
      esac
    }
    if [ $# -gt 0 ]; then
      only=1
      dirs=()
      for svc in "$@"; do
        case "$svc" in "" | .* | *.* | */*) echo "bad service name: $svc" >&2; exit 2 ;; esac
        [ -d "$root/$svc" ] || { echo "$svc: no $root/$svc on $host" >&2; exit 1; }
        dirs+=("$root/$svc/")
      done
    else
      only=0
      dirs=("$root"/*/)
    fi
    failed=""
    for dir in "''${dirs[@]}"; do
      [ -d "$dir" ] || continue
      svc=$(basename "$dir")
      case "$svc" in *.*) continue ;; esac # <svc>.moved-<date> leftovers
      # Only services installed here (unit file from `cnt deploy`); data left
      # behind without a unit is stale and not backed up.
      if [ -e ${mutable}/container@$svc.service ]; then unit=container@$svc.service
      elif [ -e ${mutable}/fleet-$svc.service ]; then unit=fleet-$svc.service
      else
        echo "$svc: not installed on $host, skipped" >&2
        [ "$only" = 0 ] || failed="$failed $svc"
        continue
      fi
      echo "== $svc ($unit)" >&2
      (
        set -eu -o pipefail
        # One run per service at a time (nightly vs `cnt move`).
        exec 9>"$staging/$svc.lock"
        flock 9
        if [ "$(systemctl is-active "$unit" || true)" = active ]; then
          runHook "$svc" || exit 1
        else
          echo "$svc: not running, hook skipped (data is at rest)" >&2
        fi
        # Consistent SQLite copies via the online backup API (host side, any
        # container kind); the live db/-wal/-shm files are excluded.
        st=$staging/$svc
        rm -rf "$st"
        install -d -m700 "$st/sqlite" || exit 1
        ex=$staging/$svc.excludes
        : > "$ex" || exit 1
        find "$dir" -xdev -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
          -not -path '*/postgres/*' -not -path '*/postgresql/*' -print0 |
        while IFS= read -r -d "" db; do
          [ "$(head -c 15 "$db")" = "SQLite format 3" ] || continue
          out="$st/sqlite''${db#$root}"
          install -d -m700 "$(dirname "$out")"
          sqlite3 "$db" ".timeout 30000" ".backup '$out'" || exit 1
          # the copy replaces the live file on restore: keep owner and mode
          chown --reference="$db" "$out"
          chmod --reference="$db" "$out"
          printf '%s\n' "$db" "$db-wal" "$db-shm" "$db-journal" >> "$ex"
          # opening an idle WAL db creates -wal/-shm; keep the app's owner
          for f in "$db-wal" "$db-shm"; do [ ! -e "$f" ] || chown --reference="$db" "$f"; done
        done || exit 1
        snap=$(restic backup --json --retry-lock 2h --host "$host" --tag fleet --tag "svc:$svc" \
          --group-by tags --exclude-caches --exclude-file="$ex" \
          --exclude-file=${excludeFile} "$root/$svc" "$st" |
          grep -o '"snapshot_id":"[0-9a-f]*"' | tail -n1 | cut -d'"' -f4) || exit 1
        [ -n "$snap" ] || { echo "$svc: restic printed no snapshot id" >&2; exit 1; }
        printf 'time=%s snapshot=%s host=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$snap" "$host" > "$stamps/.$svc.new"
        chmod 644 "$stamps/.$svc.new"
        mv -f "$stamps/.$svc.new" "$stamps/$svc"
        echo "$svc: snapshot $snap" >&2
      ) || { echo "$svc: BACKUP FAILED" >&2; failed="$failed $svc"; }
    done
    if [ "$only" = 0 ]; then
      restic forget --retry-lock 2h --prune --tag fleet --group-by tags ${lib.escapeShellArgs bcfg.pruneOpts} ||
        failed="$failed (forget)"
    fi
    if [ -n "$failed" ]; then echo "failed:$failed" >&2; exit 1; fi
  '';
  excludeFile = pkgs.writeText "fleet-backup-excludes" (lib.concatLines bcfg.exclude);
  backupUnit = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = [ "/srv/containers" ];
    }
    // lib.optionalAttrs (bcfg.environmentFile != null) {
      ConditionPathExists = bcfg.environmentFile;
    };
    environment = {
      RESTIC_CACHE_DIR = "/var/cache/fleet-backup";
    }
    // lib.optionalAttrs (bcfg.repository != null) { RESTIC_REPOSITORY = bcfg.repository; }
    // lib.optionalAttrs (bcfg.passwordFile != null) { RESTIC_PASSWORD_FILE = bcfg.passwordFile; };
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "fleet-backup";
      StateDirectoryMode = "0700";
      CacheDirectory = "fleet-backup";
      CacheDirectoryMode = "0700";
      Nice = 10;
      IOSchedulingClass = "idle";
    }
    // lib.optionalAttrs (bcfg.environmentFile != null) {
      EnvironmentFile = bcfg.environmentFile;
    };
  };
in
{
  options.ringofstorms.containers = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Host support for floating containers managed by the `containers` CLI.";
    };
    nginx.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable nginx and include ${stateDir}/nginx/*.conf in the http block.";
    };
    nginx.tls.certDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/acme/joshuabell.xyz";
      example = "/var/lib/fleet-cert/joshuabell.xyz/current";
      description = ''
        Directory holding fullchain.pem and key.pem for the generated
        internal :443 listeners, written to
        /etc/fleet-containers/nginx-tls.conf. Set to the wildcard pushed by
        h005 (hosts/wildcard-cert-receiver.nix) to drop the host's own ACME.
      '';
    };
    # Internal/edge listener split (ROUTING-PLAN §2.3). Generated vhosts put
    # public `via = edge` routes on <overlayIp>:edge.port as well; only
    # edge.peers may connect there (firewall + per-vhost check).
    nginx.edge = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "Edge listener port. Must match lib.nix edgePort and cli/routes.go edgePort.";
      };
      peers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "100.64.0.5"
          "fd7a:115c:a1e0::5"
        ];
        description = "Overlay addresses of the public edge (o002), v4 and v6.";
      };
      blockInternal = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Drop edge peers on the internal :80/:443 listener (generated vhosts
          return 444 when $fleet_edge_peer is 1). Turn on only once the edge
          proxies to the edge listener, or public names break.
        '';
      };
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "The `containers` CLI, installed system-wide.";
    };
    # Exposure ACLs for the generated internal :80/:443 servers (ROUTING-PLAN
    # §2.1): cli/routes.go includes /etc/fleet-containers/nginx-acl-<exposure>.conf
    # in every tailnet/lan server. Enforced by TCP peer, never by DNS.
    nginx.acl = {
      tailnet = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
        ];
        description = "High-trust overlay CIDRs allowed on tailnet routes (edge peers still get 444 with edge.blockInternal).";
      };
      lan = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "10.12.14.0/24" ];
        description = "The host's LAN subnet(s); lan routes allow these plus nginx.acl.tailnet.";
      };
      loopback = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also allow 127.0.0.1 and ::1 (only for local health checks via the vhost).";
      };
    };
    # Read-only GET /status.json for fleet-edge (ROUTING-PLAN.md §5.4); see
    # cli/statusserver.go for the JSON contract. Off by default.
    #
    # The firewall is NOT opened for it: today tailscale0 is a trusted
    # interface, so an overlay-IP listener is reachable from high-trust
    # tailnet nodes. Step 2 (no trusted tailscale0) must add an explicit rule
    # admitting h005 only.
    statusEndpoint = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Serve the read-only container status endpoint for fleet-edge.";
      };
      listen = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "100.64.0.13:9101";
        description = "ADDR:PORT to listen on, normally the host's overlay IP. Required when enabled (never a wildcard).";
      };
    };
    lanInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "enp3s0";
      description = ''
        The host's LAN interface, for `cnt port open --iface lan` (written to
        /etc/fleet-containers/lan-interface). null: `--iface lan` is refused.
      '';
    };
    # Private container networking (ROUTING-PLAN §8 step 5) for services
    # with net.private in service.nix: veth ve-<name>, guest
    # 10.233.<index>.2, host side lib.nix netHostAddress (10.233.0.1).
    privateNetwork.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Host side for net.private containers: masquerade 10.233.0.0/16 out
        of every non-ve interface, DNAT for their tcp/udp routes
        (fleet-net-nat @routes, filled from the ports files), no direct
        container-to-container traffic, @noinet for internet = false, and
        DNS on 10.233.0.1 (resolved stub). ve-* is not trusted.
      '';
    };
    capabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "nfs-h004"
        "intel-qsv"
      ];
      description = ''
        What this host offers to services. A service with `requires = [ ... ]`
        in service.nix is only deployed or moved to hosts that list them all
        (the CLI checks /etc/fleet-containers/capabilities/<name>).
      '';
    };
    publishedPorts = lib.mkOption {
      default = [ ];
      description = ''
        Source filters for podman ports published on a host address. netavark
        DNATs published ports in prerouting, so nixos-fw's input rules never
        see them. Each entry adds, in a prerouting chain before netavark's
        dstnat: accept from `from`, drop everyone else, for new and existing
        flows to address:port (the pre-DNAT destination).
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption { type = lib.types.port; };
            proto = lib.mkOption {
              type = lib.types.enum [
                "tcp"
                "udp"
              ];
              default = "tcp";
            };
            from = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Allowed source addresses/CIDRs (v4 and v6 may be mixed).";
            };
            comment = lib.mkOption {
              type = lib.types.str;
              default = "published port";
            };
          };
        }
      );
    };
    backup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Nightly restic backup of every floating service installed on this
          host: backupHook (if running), SQLite online copies, then one
          snapshot of /srv/containers/<svc> per service, tagged `fleet` and
          `svc:<name>` (hostname = this host). Unit: fleet-backup.service.
        '';
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "EnvironmentFile with RESTIC_REPOSITORY, RESTIC_PASSWORD and backend credentials (usually set by sec-agent configChanges). The unit only starts once it exists.";
      };
      repository = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "RESTIC_REPOSITORY, if not in environmentFile.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "RESTIC_PASSWORD_FILE, if the password is not in environmentFile.";
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "03:00";
        description = "systemd OnCalendar (with up to 15 min random delay, Persistent).";
      };
      exclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          # live DB clusters: the hooks' dumps are what gets restored
          "/srv/containers/*/postgres"
          "/srv/containers/*/postgresql/[0-9]*"
          # regenerable
          "/srv/containers/immich/mlcache"
          "/srv/containers/open-webui/data/hf_home"
          "/srv/containers/open-webui/data/transformers_home"
          "/srv/containers/open-webui/data/xet"
          "/srv/containers/open-webui/data/models--*"
          "/srv/containers/paperless/data/index"
        ];
        description = "restic exclude patterns.";
      };
      pruneOpts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "--keep-daily"
          "7"
          "--keep-weekly"
          "5"
          "--keep-monthly"
          "12"
          "--keep-yearly"
          "3"
        ];
        description = "restic forget options (applied per svc tag, across hosts).";
      };
    };
    guards = lib.mkOption {
      default = { };
      description = ''
        Storage guards. Each guard is a service `fleet-guard-<name>` that
        probes network mounts (fs type + a sentinel file, every probe hard-
        bounded with `timeout -k`) and exits on the first failure. The listed
        units get BindsTo/After on it, so they stop with it and can't start
        while it is down. After every passing probe it starts the listed units
        that are wanted at boot (the link `containers stop` removes) and not
        held (/run/fleet-containers/hold/<service>, written by `containers
        stop/backup/move`). No Upholds=, so deliberate stops stick.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            mounts = lib.mkOption {
              description = "Paths that must be live network mounts.";
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    path = lib.mkOption { type = lib.types.str; };
                    fsType = lib.mkOption {
                      type = lib.types.str;
                      default = "nfs";
                      description = "`stat -f -c %T` result (nfs4 shows as nfs).";
                    };
                    sentinel = lib.mkOption {
                      type = lib.types.str;
                      description = "File that exists only on the real share.";
                    };
                  };
                }
              );
            };
            units = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              example = {
                arr = "container@arr.service";
              };
              description = "Service name (for hold markers) to systemd unit.";
            };
            interval = lib.mkOption {
              type = lib.types.int;
              default = 30;
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        programs.extra-container.enable = true;
        boot.enableContainers = true;
        virtualisation.podman.enable = lib.mkDefault true;

        systemd.tmpfiles.rules = [
          "d /srv/containers 0755 root root -"
          "d ${stateDir} 0755 root root -"
          "d ${stateDir}/nginx 0755 root root -"
          "d ${stateDir}/ports 0755 root root -"
          "d /nix/var/nix/gcroots/fleet-containers 0755 root root -"
          "d ${holdDir} 0755 root root -"
        ];

        environment.etc =
          lib.listToAttrs (
            map (c: lib.nameValuePair "fleet-containers/capabilities/${c}" { text = ""; }) cfg.capabilities
          )
          // lib.optionalAttrs (cfg.lanInterface != null) {
            "fleet-containers/lan-interface".text = cfg.lanInterface;
          };

        # `cnt port open` (ROUTING-PLAN §8 step 2): temporary ports as nft set
        # elements with timeouts; the kernel expires them and a firewall
        # reload empties the sets (fail closed). ifname "any" is a sentinel
        # the CLI uses for --iface any; the const rules below match it on
        # every interface. Elements carry comment "svc=<svc>".
        assertions = [
          {
            assertion = config.networking.nftables.enable;
            message = "ringofstorms.containers needs networking.nftables.enable = true (cnt port uses nft sets in inet nixos-fw).";
          }
        ];
        networking.nftables.tables.nixos-fw.content = lib.mkAfter ''
          set cnt-tmp {
            comment "cnt port open: ifname . proto . port"
            type ifname . inet_proto . inet_service
            flags timeout
          }
          set cnt-tmp4 {
            comment "cnt port open --from (v4)"
            type ifname . inet_proto . inet_service . ipv4_addr
            flags interval,timeout
          }
          set cnt-tmp6 {
            comment "cnt port open --from (v6)"
            type ifname . inet_proto . inet_service . ipv6_addr
            flags interval,timeout
          }
        '';

        # Re-adds runtime ports after every firewall start or reload
        # (flushRuleset wipes them).
        systemd.services.fleet-containers-ports = {
          description = "Open firewall ports for floating containers";
          wantedBy = [ "multi-user.target" ];
          after = [ "nftables.service" ];
          partOf = [ "nftables.service" ];
          unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = applyPorts;
            ExecReload = applyPorts;
          };
        };

        # Impermanent hosts bind-mount ${mutable} from /persist after PID 1
        # has loaded units, so the boot links `containers` writes
        # (machines.target.wants for nspawn, multi-user.target.wants for
        # podman) are never seen at boot. Once the bind is up, reload and start
        # every linked unit. `containers stop` removes the link, so stopped
        # services stay stopped. Skipped where the dir is part of the root fs
        # (systemd already read it at boot).
        systemd.services.fleet-containers-boot-start = {
          description = "Start floating containers linked for boot (persisted unit dir)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "local-fs.target"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          unitConfig = {
            RequiresMountsFor = [ "/etc/systemd-mutable" ];
            ConditionPathIsMountPoint = "/etc/systemd-mutable";
          };
          path = [
            pkgs.systemd
            pkgs.coreutils
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            systemctl daemon-reload
            for l in ${mutable}/machines.target.wants/*.service ${mutable}/multi-user.target.wants/*.service; do
              [ -e "$l" ] || continue
              u=$(basename "$l")
              echo "starting $u"
              systemctl start --no-block "$u"
            done
          '';
        };

        # podman --userns=auto takes ranges from the "containers" subuid entry.
        users.users.containers = {
          isSystemUser = true;
          group = "containers";
          subUidRanges = [
            {
              startUid = 2147483647;
              count = 2147483648;
            }
          ];
          subGidRanges = [
            {
              startGid = 2147483647;
              count = 2147483648;
            }
          ];
        };
        users.groups.containers = { };

        environment.systemPackages = [
          pkgs.rsync
          cfg.package
        ];
        environment.shellAliases.cnt = "containers";

        # Network for podman services with `internet = false`. Traffic
        # *from* it is dropped (internet, LAN, tailnet, host, DNS), including
        # already established connections, so revoking @online also cuts a
        # running download. Replies to inbound connections on published
        # ports are `ct direction reply` and pass.
        # Units check this table exists before starting (fail closed).
        # `containers online <svc>` puts the container IP in @online with a
        # timeout; a firewall reload empties the set (fail closed again).
        networking.nftables.tables.fleet-noinet = {
          family = "inet";
          content = ''
            set online {
              type ipv4_addr
              flags timeout
            }
            chain forward {
              type filter hook forward priority filter - 10; policy accept;
              iifname "fleet-noinet" ip saddr @online accept
              iifname "fleet-noinet" ct direction original drop
            }
            chain input {
              type filter hook input priority filter - 10; policy accept;
              iifname "fleet-noinet" ip saddr @online accept
              iifname "fleet-noinet" ct direction original drop
            }
          '';
        };
        # See publishedPorts. Runs before netavark's dstnat (priority -100) and
        # lives in its own declarative table, so podman restarts can't remove it.
        networking.nftables.tables.fleet-publish = lib.mkIf (cfg.publishedPorts != [ ]) {
          family = "inet";
          content = ''
            chain prerouting {
              type filter hook prerouting priority dstnat - 10; policy accept;
            ${lib.concatMapStrings (
              p:
              let
                fam = if lib.hasInfix ":" p.address then "ip6" else "ip";
                from = builtins.filter (a: (lib.hasInfix ":" a) == (fam == "ip6")) p.from;
              in
              lib.optionalString (from != [ ]) ''
                ${fam} daddr ${p.address} ${p.proto} dport ${toString p.port} ${fam} saddr { ${lib.concatStringsSep ", " from} } accept comment "${p.comment}"
              ''
              + ''
                ${fam} daddr ${p.address} ${p.proto} dport ${toString p.port} drop comment "${p.comment}: other sources"
              ''
            ) cfg.publishedPorts}
            }
          '';
        };

        # DNS (aardvark-dns on the bridge) for containers that are online.
        # Only reachable here once the chain above let the packet through.
        # Then the `cnt port` sets declared above.
        networking.firewall.extraInputRules = ''
          iifname "fleet-noinet" meta l4proto { tcp, udp } th dport 53 accept
          iifname . meta l4proto . th dport @cnt-tmp accept comment "cnt port"
          "any" . meta l4proto . th dport @cnt-tmp accept comment "cnt port --iface any"
          iifname . meta l4proto . th dport . ip saddr @cnt-tmp4 accept comment "cnt port --from"
          "any" . meta l4proto . th dport . ip saddr @cnt-tmp4 accept comment "cnt port --iface any --from"
          iifname . meta l4proto . th dport . ip6 saddr @cnt-tmp6 accept comment "cnt port --from v6"
          "any" . meta l4proto . th dport . ip6 saddr @cnt-tmp6 accept comment "cnt port --iface any --from v6"
        '';
      }

      # Runtime vhosts: `containers deploy` writes <svc>.conf into the include
      # dir, runs `nginx -t` (restoring the previous file and keeping the rejected one
      # as .broken on failure) and then
      # `systemctl reload nginx`. No rebuild is needed for new sites.
      (lib.mkIf cfg.nginx.enable {
        services.nginx = {
          enable = true;
          enableReload = true;
          # Edge/internal split (ROUTING-PLAN §2.3), used by generated vhosts:
          #   $fleet_edge_peer          1 when the TCP peer is the edge (o002).
          #                             $realip_remote_addr is the real peer even
          #                             where real_ip rewrote $remote_addr.
          #   $fleet_edge_block_internal 1 when the internal listener must drop
          #                             this peer (nginx.edge.blockInternal).
          #   /etc/fleet-containers/nginx-edge-realip.conf, included by edge
          #                             servers only: trust X-Forwarded-For from the edge.
          appendHttpConfig = ''
            map $realip_remote_addr $fleet_edge_peer {
              default 0;
            ${lib.concatMapStrings (p: "  ${p} 1;\n") cfg.nginx.edge.peers}}
            map $realip_remote_addr $fleet_edge_block_internal {
              default 0;
            ${
              lib.optionalString cfg.nginx.edge.blockInternal (
                lib.concatMapStrings (p: "  ${p} 1;\n") cfg.nginx.edge.peers
              )
            }}
            # Edge listener catch-all: unknown names (or a route that is no
            # longer public here) get 444, never another route's backend.
            server {
              listen ${toString cfg.nginx.edge.port} default_server;
              listen [::]:${toString cfg.nginx.edge.port} default_server;
              server_name _;
              return 444;
            }
            include ${stateDir}/nginx/*.conf;
          '';
          # Drop anything not matched by a real vhost.
          virtualHosts."_" = {
            default = lib.mkDefault true;
            locations."/".return = lib.mkDefault "444";
          };
        };
        environment.etc."fleet-containers/nginx-edge-realip.conf".text =
          lib.concatMapStrings (p: "set_real_ip_from ${p};\n") cfg.nginx.edge.peers
          + "real_ip_header X-Forwarded-For;\nreal_ip_recursive off;\n";
        # Certificate for the generated internal :443 listeners (one place;
        # cli/routes.go only `include`s this file). ROUTING-PLAN §8 step 4.
        environment.etc."fleet-containers/nginx-tls.conf".text = ''
          ssl_certificate ${cfg.nginx.tls.certDir}/fullchain.pem;
          ssl_certificate_key ${cfg.nginx.tls.certDir}/key.pem;
        '';
        # Exposure ACLs (cli/routes.go writeExposureACL). Server level, so
        # every location incl. /oauth2/ inherits them.
        environment.etc."fleet-containers/nginx-acl-tailnet.conf".text = aclText cfg.nginx.acl.tailnet;
        environment.etc."fleet-containers/nginx-acl-lan.conf".text = aclText (
          cfg.nginx.acl.tailnet ++ cfg.nginx.acl.lan
        );
        # Edge listener: only the edge peers, only on the tailnet.
        networking.firewall.extraInputRules = lib.concatMapStrings (
          p:
          let
            fam = if lib.hasInfix ":" p then "ip6" else "ip";
          in
          ''
            iifname "tailscale0" ${fam} saddr ${p} tcp dport ${toString cfg.nginx.edge.port} accept comment "nginx edge listener (ROUTING-PLAN 2.3)"
          ''
        ) cfg.nginx.edge.peers;
        systemd.services.nginx.serviceConfig.ReadOnlyPaths = [ "${stateDir}/nginx" ];
        # `containers deploy` validates new sites with `nginx -t` before reloading.
        environment.systemPackages = [ config.services.nginx.package ];

        # `cnt expose` (ROUTING-PLAN §8 step 7): the CLI arms an exact
        # transient timer per override; this sweep is the backstop. It runs
        # at boot before nginx (an override that expired while the host was
        # down never serves again) and every minute (a lost transient timer
        # delays a revert by at most that). See cli/expose.go.
        systemd.tmpfiles.rules = [ "d ${stateDir}/overrides 0755 root root -" ];
        systemd.services.fleet-containers-expose-expire = {
          description = "Revert expired cnt expose overrides";
          wantedBy = [ "multi-user.target" ];
          before = [ "nginx.service" ];
          after = [ "local-fs.target" ];
          path = [
            config.services.nginx.package
            pkgs.systemd
            pkgs.util-linux
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe cfg.package} expose-expire --all";
            # Never hang a boot or the minute timer (it only edits files and queues a reload).
            TimeoutStartSec = "2min";
          };
        };
        systemd.timers.fleet-containers-expose-expire = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "1min";
            AccuracySec = "5s";
          };
        };
      })

      # Host daemons this module declares, for `cnt audit` (cli/routes.go
      # hostListenersFile): "<proto> <addr> <port> <owner>".
      # The status endpoint's listen is asserted to be IP:PORT below.
      {
        environment.etc."fleet-containers/host-listeners".text =
          let
            m = builtins.match "\\[?([0-9a-fA-F:.]+)]?:([0-9]+)" cfg.statusEndpoint.listen;
          in
          lib.optionalString (cfg.statusEndpoint.enable && m != null) ''
            tcp ${builtins.elemAt m 0} ${builtins.elemAt m 1} host (status endpoint)
          '';
      }

      # Runs unprivileged: `systemctl show` reads unit properties over the
      # system D-Bus, which systemd allows to any user, and the unit dir and
      # gcroot dir are world-readable (0755). So DynamicUser with no
      # capabilities and a read-only view of the system is enough.
      # No PrivateUsers: D-Bus EXTERNAL auth from inside a user namespace can
      # fail (the uid the client sends differs from the peer uid on the socket).
      (lib.mkIf cfg.statusEndpoint.enable {
        assertions = [
          {
            assertion =
              builtins.match "(\\[[0-9a-fA-F:]+]|[0-9.]+):[0-9]+" cfg.statusEndpoint.listen != null
              && !(lib.hasPrefix "0.0.0.0:" cfg.statusEndpoint.listen)
              && !(lib.hasPrefix "[::]:" cfg.statusEndpoint.listen);
            message = "ringofstorms.containers.statusEndpoint.listen must be an explicit IP:PORT (e.g. the overlay IP \"100.64.0.13:9101\"), not empty or a wildcard.";
          }
        ];
        systemd.services.fleet-containers-status = {
          description = "Read-only status endpoint for floating containers (fleet-edge)";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "tailscaled.service"
          ];
          path = [ pkgs.systemd ];
          serviceConfig = {
            ExecStart = "${lib.getExe cfg.package} status-server --listen ${cfg.statusEndpoint.listen} --host ${config.networking.hostName}";
            # The overlay IP may appear after boot; retry until it can bind.
            Restart = "always";
            RestartSec = 5;
            DynamicUser = true;
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
            ProtectProc = "invisible";
            ProcSubset = "pid";
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
            # AF_UNIX for the D-Bus socket used by `systemctl show`.
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            UMask = "0077";
          };
        };
      })
      (lib.mkIf bcfg.enable {
        environment.systemPackages = [
          (pkgs.writeShellScriptBin "fleet-restic" ''
            # restic with this host's fleet-backup credentials (root only)
            ${lib.optionalString (bcfg.environmentFile != null) "set -a; . ${bcfg.environmentFile}; set +a"}
            ${lib.optionalString (bcfg.repository != null) "export RESTIC_REPOSITORY=${bcfg.repository}"}
            ${lib.optionalString (bcfg.passwordFile != null) "export RESTIC_PASSWORD_FILE=${bcfg.passwordFile}"}
            export RESTIC_CACHE_DIR=/var/cache/fleet-backup
            exec ${pkgs.restic}/bin/restic "$@"
          '')
        ];
        # `cnt move` checks this marker on the target (fleet-restic present).
        environment.etc."fleet-containers/backup".text = "fleet-backup stamps: ${backupStampDir}\n";
        systemd.services.fleet-backup = backupUnit // {
          description = "restic backup of floating containers (ROUTING-PLAN §9.1)";
          serviceConfig = backupUnit.serviceConfig // {
            ExecStart = backupScript;
          };
        };
        # One service now, no prune (`cnt move`): systemctl start fleet-backup-svc@puzzles
        systemd.services."fleet-backup-svc@" = backupUnit // {
          description = "restic backup of floating container %i (ROUTING-PLAN §9.1)";
          serviceConfig = backupUnit.serviceConfig // {
            ExecStart = "${backupScript} %i";
          };
        };
        systemd.timers.fleet-backup = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = bcfg.schedule;
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        };
      })

      (lib.mkIf (cfg.guards != { }) { systemd = guardUnits; })

      (lib.mkIf cfg.privateNetwork.enable {
        assertions = [
          {
            assertion = config.services.resolved.enable;
            message = "ringofstorms.containers.privateNetwork needs systemd-resolved (guest DNS is its stub on 10.233.0.1).";
          }
        ];
        boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = lib.mkDefault true;
        # Guests ask the host's resolver; freebind, so it binds before any veth exists.
        services.resolved.settings.Resolve.DNSStubListenerExtra = [ "10.233.0.1" ];
        # Host side of a guest veth, the moment nspawn creates it
        # (ROUTING-PLAN §8 step 5). nixos-containers only configures
        # ve-<name> in container@'s postStart, which (Type=notify) runs after
        # the guest is READY, so guest units that need the network at boot
        # would stall. udev fires on the veth add; the oneshot reads the
        # container's /etc/nixos-containers/<name>.conf and only touches our
        # scheme (HOST_ADDRESS 10.233.0.1, LOCAL_ADDRESS 10.233.*). No
        # networkd needed (h001 runs dhcpcd, which denies ve-*; NM hosts get
        # ve-* unmanaged below). lib.nix makes postStart idempotent.
        services.udev.extraRules = ''
          SUBSYSTEM=="net", ACTION=="add", KERNEL=="ve-*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="fleet-veth@%k.service"
        '';
        systemd.services."fleet-veth@" = {
          description = "Host side of container veth %i (net.private)";
          path = [ pkgs.iproute2 ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.writeShellScript "fleet-veth" ''
              set -u
              ifc=$1
              conf=/etc/nixos-containers/''${ifc#ve-}.conf
              [ -r "$conf" ] || exit 0
              h=$(sed -n 's/^HOST_ADDRESS=//p' "$conf")
              l=$(sed -n 's/^LOCAL_ADDRESS=//p' "$conf")
              [ "$h" = 10.233.0.1 ] || exit 0
              case "$l" in 10.233.*) ;; *) exit 0 ;; esac
              ip link set dev "$ifc" up
              ip addr replace "$h" dev "$ifc"
              ip route replace "$l" dev "$ifc"
              echo "$ifc: $h -> $l"
            ''} %i";
          };
        };
        networking.networkmanager.unmanaged = lib.mkIf config.networking.networkmanager.enable [
          "interface-name:ve-*"
        ];
        # Guest isolation (ROUTING-PLAN §8 step 5). Scope: interfaces in
        # @guests (ve-<name> of net.private services, from the ports files)
        # and, as a static fallback while the sets are being refilled, any
        # source in 10.233.0.0/16. Legacy privateNetwork containers on other
        # ve-* interfaces/addresses (lio's 10.0.0.x) are not touched.
        networking.nftables.tables.fleet-net = {
          family = "inet";
          content = builtins.readFile ./cli/fleet-net.nft;
        };
        networking.nftables.tables.fleet-net-nat = {
          family = "ip";
          # Tailnet routes only for real tailnet peers (tailscale0, overlay
          # range, not the edge); see fleet-net-nat.nft.
          content =
            builtins.replaceStrings
              [ "@EDGE4@" ]
              [
                (lib.concatStringsSep ", " (
                  builtins.filter (p: !(lib.hasInfix ":" p)) cfg.nginx.edge.peers ++ [ "0.0.0.0" ]
                ))
              ]
              (builtins.readFile ./cli/fleet-net-nat.nft);
        };
        networking.firewall.extraInputRules = ''
          iifname "ve-*" ip daddr 10.233.0.1 meta l4proto { tcp, udp } th dport 53 accept comment "guest DNS (resolved stub)"
        '';
        # Only used where networking.firewall.filterForward is on (h003).
        # fleet-net's forward chain has already dropped what must not pass.
        networking.firewall.extraForwardRules = ''
          iifname "ve-*" accept comment "net.private egress"
          oifname "ve-*" ct status dnat accept comment "net.private tcp/udp routes"
        '';
      })
    ]
  );
}
