{
  inputs = {
  };

  outputs =
    {
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          with lib;
          {
            options.mods.nebula = {
              serviceEnabled = mkOption {
                type = types.bool;
                default = true;
                description = "Whether the nebula service should run.";
              };
            };
            config = {
              environment.systemPackages = with pkgs; [
                nebula
                traceroute # for debugging
              ];

              networking.firewall.allowedUDPPorts = [ 4242 ];

              systemd.services."nebula" = mkIf config.mods.nebula.serviceEnabled {
                description = "Nebula VPN service";
                wants = [
                  "basic.target"
                  "network.target"
                  "network-online.target"
                  "nss-lookup.target"
                ];
                after = [
                  "basic.target"
                  "network.target"
                  "network-online.target"
                  "nss-lookup.target"
                ];
                before = [ "sshd.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  Type = "notify";
                  Restart = "always";
                  RestartSec = 1;
                  ExecStart = "${pkgs.nebula}/bin/nebula -config /etc/nebula/config.yml";
                  UMask = "0027";
                  CapabilityBoundingSet = "CAP_NET_ADMIN";
                  AmbientCapabilities = "CAP_NET_ADMIN";
                  LockPersonality = true;
                  NoNewPrivileges = true;
                  PrivateDevices = false; # needs access to /dev/net/tun (below)
                  DeviceAllow = "/dev/net/tun rw";
                  DevicePolicy = "closed";
                  PrivateTmp = true;
                  PrivateUsers = false; # CapabilityBoundingSet needs to apply to the host namespace
                  ProtectClock = true;
                  ProtectControlGroups = true;
                  ProtectHome = true;
                  ProtectHostname = true;
                  ProtectKernelLogs = true;
                  ProtectKernelModules = true;
                  ProtectKernelTunables = true;
                  ProtectProc = "invisible";
                  ProtectSystem = "strict";
                  RestrictNamespaces = true;
                  RestrictSUIDSGID = true;
                };
                unitConfig = {
                  StartLimitIntervalSec = 5;
                  StartLimitBurst = 3;
                };
              };
            };
          };
      };
    };
}
