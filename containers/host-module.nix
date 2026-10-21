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
  applyPorts = pkgs.writeShellScript "fleet-containers-apply-ports" ''
    set -u
    nft=${pkgs.nftables}/bin/nft
    shopt -s nullglob
    for f in ${stateDir}/ports/*; do
      while read -r proto port; do
        case "$proto" in tcp|udp) ;; *) continue ;; esac
        case "$port" in ""|*[!0-9]*) continue ;; esac
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
    privateNetwork = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Allow containers with privateNetwork (ve-* interfaces) to reach the
          internet. Adds ve-+ to NAT and trusts and forwards it.
        '';
      };
      externalInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Interface to NAT container traffic out of.";
      };
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
      })

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

      (lib.mkIf (cfg.guards != { }) { systemd = guardUnits; })

      (lib.mkIf cfg.privateNetwork.enable {
        networking.nat = {
          enable = true;
          internalInterfaces = [ "ve-+" ];
          externalInterface = lib.mkIf (
            cfg.privateNetwork.externalInterface != null
          ) cfg.privateNetwork.externalInterface;
        };
        networking.firewall.trustedInterfaces = [ "ve-+" ];
        networking.firewall.extraForwardRules = lib.mkBefore ''
          iifname "ve-*" accept
          oifname "ve-*" accept
        '';
      })
    ]
  );
}
