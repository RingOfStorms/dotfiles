# vaultwarden — migrated off o001 into an h001 NixOS container.
#
# SQLite-backed (single-user vault); data + backups bind-mounted from the
# host (uid/gid 114, matching the o001 layout so the Phase 0 backup restores
# 1:1). The vaultwarden_env secret is rendered on h001 via secrets-bao
# (declared in _constants.nix:secrets) and bind-mounted read-only.
#
# o002's nginx proxies vault.joshuabell.xyz over the tailnet to h001; this
# module's vhost terminates TLS (wildcard cert) and proxies to the container.
{
  constants,
  config,
  lib,
  fleet,
  ...
}:
let
  name = "vaultwarden";
  c = constants.services.vaultwarden;
  net = constants.containerNetwork;

  hostDataDir = c.dataDir;

  hostAddress = net.hostAddress;
  containerAddress = c.containerIp;
  hostAddress6 = net.hostAddress6;
  containerAddress6 = c.containerIp6;

  baoSecrets = config.ringofstorms.secretsBao.secrets or { };
  envSecret = "vaultwarden_env_2026-03-15";
  hasVaultwardenEnv = baoSecrets ? ${envSecret};

  # Host user (uid/gid 114) owning the bind-mounted data dirs.
  users = {
    users.${name} = {
      isSystemUser = true;
      group = name;
      uid = c.uid;
    };
    groups.${name}.gid = c.gid;
  };
in
{
  # Ensure users exist on host machine with same IDs as container
  inherit users;

  # Ensure data dirs exist on host with the right ownership
  system.activationScripts.createVaultwardenDirs = ''
    mkdir -p ${hostDataDir}/data
    mkdir -p ${hostDataDir}/backups
    chown -R ${toString c.uid}:${toString c.gid} ${hostDataDir}
    chmod -R 750 ${hostDataDir}
  '';

  services.nginx = lib.mkIf hasVaultwardenEnv {
    virtualHosts = {
      "${c.domain}" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
        locations."/" = {
          proxyWebsockets = true;
          proxyPass = "http://${containerAddress}:${toString c.port}";
        };
      };
    };
  };

  containers.${name} = lib.mkIf hasVaultwardenEnv {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = hostAddress;
    localAddress = containerAddress;
    hostAddress6 = hostAddress6;
    localAddress6 = containerAddress6;
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
        hostPath = baoSecrets.${envSecret}.path;
        isReadOnly = true;
      };
    };
    config =
      { ... }:
      {
        system.stateVersion = "24.11";

        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [ c.port ];
          };
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;

        # Ensure user exists on container
        inherit users;

        services.vaultwarden = {
          enable = true;
          dbBackend = "sqlite";
          backupDir = "/var/lib/backups/vaultwarden";
          environmentFile = "/var/secrets/vaultwarden.env";
          config = {
            DOMAIN = "https://${c.domain}";
            SIGNUPS_ALLOWED = false;
            ROCKET_PORT = builtins.toString c.port;
            # Bind on all container interfaces so h001 nginx can reach it.
            ROCKET_ADDRESS = "0.0.0.0";
          };
        };
      };
  };
}
