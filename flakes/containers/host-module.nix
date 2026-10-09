# Host side of the floating-services setup. Import it once per host:
#   inputs.containers.nixosModules.default
#
# After one rebuild with this module, the host can run any app in
# flakes/containers/<app>/ without another rebuild:
#   - extra-container installs nspawn units into /etc/systemd-mutable/system
#   - podman services install the same way (see lib.nix mkPodmanService)
#   - nginx includes /var/lib/boxes/nginx/*.conf (written by `boxes`)
#   - ports listed in /var/lib/boxes/ports/<name> are opened in the firewall
#     (added to the nixos-fw `temp-ports` set and re-applied whenever the
#     firewall is reloaded)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boxes;
  stateDir = "/var/lib/boxes";
  applyPorts = pkgs.writeShellScript "boxes-apply-ports" ''
    set -u
    nft=${pkgs.nftables}/bin/nft
    shopt -s nullglob
    for f in ${stateDir}/ports/*; do
      while read -r proto port; do
        case "$proto" in tcp|udp) ;; *) continue ;; esac
        case "$port" in ""|*[!0-9]*) continue ;; esac
        $nft add element inet nixos-fw temp-ports "{ $proto . $port }" \
          || echo "boxes: could not open $proto/$port (from $f)" >&2
      done < "$f"
    done
  '';
in
{
  options.boxes = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Host support for floating containers managed by the `boxes` CLI.";
    };
    nginx.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable nginx and include ${stateDir}/nginx/*.conf in the http block.";
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
          "d /nix/var/nix/gcroots/boxes 0755 root root -"
        ];

        # Re-adds runtime ports after every firewall start or reload
        # (flushRuleset wipes them).
        systemd.services.boxes-ports = {
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

        environment.systemPackages = [ pkgs.rsync ];
      }

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
