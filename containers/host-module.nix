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
    package = lib.mkOption {
      type = lib.types.package;
      description = "The `containers` CLI, installed system-wide.";
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

        environment.etc = lib.listToAttrs (
          map (c: lib.nameValuePair "fleet-containers/capabilities/${c}" { text = ""; }) cfg.capabilities
        );

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
          path = [ pkgs.systemd pkgs.coreutils ];
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
        # DNS (aardvark-dns on the bridge) for containers that are online.
        # Only reachable here once the chain above let the packet through.
        networking.firewall.extraInputRules = ''
          iifname "fleet-noinet" meta l4proto { tcp, udp } th dport 53 accept
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
          appendHttpConfig = ''
            include ${stateDir}/nginx/*.conf;
          '';
          # Drop anything not matched by a real vhost.
          virtualHosts."_" = {
            default = lib.mkDefault true;
            locations."/".return = lib.mkDefault "444";
          };
        };
        systemd.services.nginx.serviceConfig.ReadOnlyPaths = [ "${stateDir}/nginx" ];
        # `containers deploy` validates new sites with `nginx -t` before reloading.
        environment.systemPackages = [ config.services.nginx.package ];
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
