{
  lib,
  config,
  constants,
  ...
}:
let
  name = "youtarr";
  c = constants.services.youtarr;
in
{
  config = lib.mkIf config.nixarr.enable {
    virtualisation.oci-containers.containers = {
      "${name}" = {
        image = "dialmaster/youtarr:latest";
        volumes = [
          "${c.dataDir}/config:/app/config"
          "${c.dataDir}/images:/app/server/images"
          "${c.dataDir}/jobs:/app/jobs"
          "${c.mediaDir}:/usr/src/app/data"
        ];
        environment = {
          PUID = toString c.uid;
          PGID = toString c.gid;
          DB_HOST = "127.0.0.1";
          DB_PORT = toString c.dbPort;
          DB_USER = "root";
          DB_PASSWORD = "123qweasd";
          DB_NAME = name;
        };
        extraOptions = [ "--network=host" ];
        dependsOn = [ "${name}-db" ];
      };

      "${name}-db" = {
        image = "mariadb:10.3";
        volumes = [
          "${c.dataDir}/database:/var/lib/mysql"
        ];
        environment = {
          MYSQL_ROOT_PASSWORD = "123qweasd";
          MYSQL_DATABASE = name;
        };
        extraOptions = [ "--network=host" ];
        cmd = [
          "--port=${toString c.dbPort}"
          "--character-set-server=utf8mb4"
          "--collation-server=utf8mb4_unicode_ci"
        ];
      };
    };

    users = {
      groups.${name}.gid = c.gid;
      users.${name} = {
        isSystemUser = true;
        group = name;
        uid = c.uid;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${c.dataDir}' 0775 ${name} ${name} - -"
      "d '${c.dataDir}/config' 0775 ${name} ${name} - -"
      "d '${c.dataDir}/images' 0775 ${name} ${name} - -"
      "d '${c.dataDir}/jobs' 0775 ${name} ${name} - -"
      "d '${c.dataDir}/database' 0775 999 999 - -"
      "d '${c.mediaDir}' 0775 ${name} ${name} - -"
    ];

    # Both containers run in the VPN namespace so they share localhost
    systemd.services.podman-youtarr.vpnconfinement = {
      enable = true;
      vpnnamespace = "wg";
    };

    systemd.services.podman-youtarr-db.vpnconfinement = {
      enable = true;
      vpnnamespace = "wg";
    };

    vpnNamespaces.wg.portMappings = [
      {
        from = c.internalPort;
        to = c.internalPort;
      }
    ];

    services.nginx = {
      virtualHosts = {
        "${name}" = {
          serverName = "h001.net.joshuabell.xyz";
          listen = [
            {
              port = c.externalPort;
              addr = "0.0.0.0";
            }
          ];
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://192.168.15.1:${toString c.internalPort}";
          };
        };
      };
    };
  };
}
