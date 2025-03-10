{
  lib,
  config,
  ...
}:
let
  name = "vaultwarden";
  hostDataDir = "/var/lib/${name}";
  hostAddress = "192.168.100.2";
  localAddress = "192.168.100.111";

  binds = [
    {
      host = "${hostDataDir}";
      container = "/data";
      user = "vaultwarden";
      uid = 114;
    }
  ];
in
{
  users = lib.foldl (
    acc: bind:
    {
      users.${bind.user} = {
        isSystemUser = true;
        home = bind.host;
        createHome = true;
        group = bind.user;
        uid = bind.uid;
      };
      groups.${bind.user}.gid = bind.uid;
    }
    // acc
  ) { } binds;

  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    inherit localAddress hostAddress;
    bindMounts = lib.foldl (
      acc: bind:
      {
        "${bind.container}" = {
          hostPath = bind.host;
          isReadOnly = false;
        };
      }
      // acc
    ) { } binds;
    config =
      { ... }:
      {
        system.stateVersion = "24.11";
        users = lib.foldl (
          acc: bind:
          {
            users.${bind.user} = {
              isSystemUser = true;
              home = bind.container;
              uid = bind.uid;
              group = bind.user;
            };
            groups.${bind.user}.gid = bind.uid;
          }
          // acc
        ) { } binds;

        services.vaultwarden = {
          enable = true;
          dbBackend = "sqlite";
          backupDir = "/data/backups";
          config = {
            DOMAIN = "https://vault.joshuabell.xyz";
            SIGNUPS_ALLOWED = false;
          };
        };
        networking.firewall = {
          enable = true;
          allowedTCPPorts = [ 8222 ];
        };
      };
  };

  services.nginx.virtualHosts."vault.joshuabell.xyz" = {
    enableACME = true;
    forceSSL = true;
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://${localAddress}:8222"; # vaultwarden TODO left off here the port is 8000 depsite the docs showing 8222 as default, set ecplisit
      };
    };
  };
}
