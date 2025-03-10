{
  lib,
  config,
  ...
}:
let
  name = "vaultwarden";
  hostDataDir = "/var/lib/${name}";
  localAddress = "192.168.100.111";

  binds = [
    {
      host = "${hostDataDir}";
      container = "/data";
      user = config.users.users.vaultwarden.name;
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
      };
      groups.${bind.user} = { };
    }
    // acc
  ) { } binds;

  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = "192.168.100.2";
    localAddress = localAddress;
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
        services.vaultwarden = {
          enable = true;
          dbBackend = "sqlite";
          backupDir = "/data/backups";
          config = {
            DOMAIN = "https://vault.joshuabell.xyz";
            SIGNUPS_ALLOWED = true;
          };
        };
        networking.firewall.allowedTCPPorts = [
          8222 # web http
        ];
      };
  };

  services.nginx.virtualHosts."vault.joshuabell.xyz" = {
    enableACME = true;
    forceSSL = true;
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://${localAddress}:8222"; # vaultwarden
      };
    };
  };
}
