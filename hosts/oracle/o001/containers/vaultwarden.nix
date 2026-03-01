{
  config,
  constants,
  lib,
  ...
}:
let
  vw = constants.services.vaultwarden;
  name = "vaultwarden";
  user = name;
  uid = vw.uid;
  hostDataDir = vw.dataDir;

  v_port = vw.port;
  
  hasSecret =
    secret:
    let
      secrets = config.age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
{
  users = {
    users.${user} = {
      isSystemUser = true;
      group = user;
      inherit uid;
    };
    groups.${user}.gid = uid;
  };
  system.activationScripts.createMediaServerDirs = ''
    mkdir -p ${hostDataDir}/data
    mkdir -p ${hostDataDir}/backups
    chown -R ${toString uid}:${toString uid} ${hostDataDir}
    chmod -R 750 ${hostDataDir}
  '';

  containers.${name} = lib.mkIf (hasSecret "vaultwarden_env") {
    ephemeral = true;
    autoStart = true;
    privateNetwork = false;
    bindMounts = {
      "/var/lib/vaultwarden" = {
        hostPath = "${hostDataDir}/data";
        isReadOnly = false;
      };
      "/var/lib/backups/vaultwarden" = {
        hostPath = "${hostDataDir}/backups";
        isReadOnly = false;
      };
      "/var/secrets/vaultwarden.env" = {
        hostPath = config.age.secrets.vaultwarden_env.path;
        isReadOnly = true;
      };
    };
    config =
      { ... }:
      {
        system.stateVersion = "24.11";
        users = {
          users.${user} = {
            isSystemUser = true;
            group = user;
            inherit uid;
          };
          groups.${user}.gid = uid;
        };

        services.vaultwarden = {
          enable = true;
          dbBackend = "sqlite";
          backupDir = "/var/lib/backups/vaultwarden";
          environmentFile = "/var/secrets/vaultwarden.env";
          config = {
            DOMAIN = "https://${vw.domain}";
            SIGNUPS_ALLOWED = false;
            ROCKET_PORT = builtins.toString v_port;
            ROCKET_ADDRESS = "127.0.0.1";
          };
        };
      };
  };

  services.nginx.virtualHosts."${vw.domain}" = lib.mkIf (hasSecret "vaultwarden_env") {
    enableACME = true;
    forceSSL = true;
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${builtins.toString v_port}";
      };
    };
  };
}
