# atuin sync server — migrated off o001 into an h001 NixOS container with its
# own internal postgres (modeled on the forgejo container pattern).
#
# o001/o002 only does TLS termination now: o002's nginx proxies
# atuin.joshuabell.xyz over the tailnet to h001, and h001's nginx (this
# module's vhost) terminates and proxies to the container.
{
  constants,
  config,
  lib,
  fleet,
  ...
}:
let
  name = "atuin";
  c = constants.services.atuin;
  net = constants.containerNetwork;

  hostDataDir = c.dataDir;

  hostAddress = net.hostAddress;
  containerAddress = c.containerIp;
  hostAddress6 = net.hostAddress6;
  containerAddress6 = c.containerIp6;

  binds = [
    # Postgres data, must use postgres user in container and host
    {
      host = "${hostDataDir}/postgres";
      container = "/var/lib/postgresql/17";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
    # Postgres backups
    {
      host = "${hostDataDir}/backups/postgres";
      container = "/var/backup/postgresql";
      user = "postgres";
      uid = config.ids.uids.postgres;
      gid = config.ids.gids.postgres;
    }
  ];
  uniqueUsers = lib.foldl' (
    acc: bind: if lib.lists.any (item: item.user == bind.user) acc then acc else acc ++ [ bind ]
  ) [ ] binds;
  users = {
    users = lib.listToAttrs (
      lib.map (u: {
        name = u.user;
        value = {
          isSystemUser = true;
          name = u.user;
          uid = u.uid;
          group = u.user;
        };
      }) uniqueUsers
    );

    groups = lib.listToAttrs (
      lib.map (g: {
        name = g.user;
        value.gid = g.gid;
      }) uniqueUsers
    );
  };
in
{
  services.nginx = {
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

  # Ensure users exist on host machine with same IDs as container
  inherit users;

  # Ensure directories exist on host machine
  system.activationScripts.createAtuinDirs = ''
    ${lib.concatStringsSep "\n" (
      lib.map (bind: ''
        mkdir -p ${bind.host}
        chown ${toString bind.user}:${toString bind.gid} ${bind.host}
        chmod 750 ${bind.host}
      '') binds
    )}
  '';

  containers.${name} = {
    ephemeral = true;
    autoStart = true;
    privateNetwork = true;
    hostAddress = hostAddress;
    localAddress = containerAddress;
    hostAddress6 = hostAddress6;
    localAddress6 = containerAddress6;
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
      { config, pkgs, ... }:
      {
        system.stateVersion = "24.11";

        networking = {
          firewall = {
            enable = true;
            allowedTCPPorts = [ c.port ];
          };
          # Use systemd-resolved inside the container
          # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
          useHostResolvConf = lib.mkForce false;
        };
        services.resolved.enable = true;

        # Ensure users exist on container
        inherit users;

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_17.withJIT;
          enableJIT = true;
          authentication = ''
            local all all trust
            host all all 127.0.0.1/8 trust
            host all all ::1/128 trust
            host all all fc00::1/128 trust
          '';
        };

        # Backup database
        services.postgresqlBackup = {
          enable = true;
        };

        services.atuin = {
          enable = true;
          openRegistration = false;
          openFirewall = false;
          # Bind on all container interfaces so h001 nginx can reach it.
          host = "0.0.0.0";
          port = c.port;
        };
      };
  };
}
