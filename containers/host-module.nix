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
        ];

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

        # podman --userns=auto takes ranges from the "containers" subuid entry.
        users.users.containers = {
          isSystemUser = true;
          group = "containers";
          subUidRanges = [ { startUid = 2147483647; count = 2147483648; } ];
          subGidRanges = [ { startGid = 2147483647; count = 2147483648; } ];
        };
        users.groups.containers = { };

        environment.systemPackages = [
          pkgs.rsync
          cfg.package
        ];
        environment.shellAliases.cnt = "containers";

        # Network for podman services with `internet = false`. New
        # connections *from* it are dropped (internet, LAN, tailnet, host,
        # DNS); replies to inbound connections on published ports pass.
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
              iifname "fleet-noinet" ct state new drop
            }
            chain input {
              type filter hook input priority filter - 10; policy accept;
              iifname "fleet-noinet" ip saddr @online accept
              iifname "fleet-noinet" ct state new drop
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
