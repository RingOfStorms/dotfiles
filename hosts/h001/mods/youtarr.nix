{
  lib,
  config,
  ...
}:
let
  name = "youtarr";
  gid = 187;
  uid = 187;
  port = 3087;
  dbPort = 3321;
  hostDataDir = "/var/lib/${name}";
  mediaDir = "/nfs/h002/${name}/media";
in
{
  config = lib.mkIf config.nixarr.enable {
    virtualisation.oci-containers.containers = {
      "${name}" = {
        image = "dialmaster/youtarr:latest";
        # No ports here - using shared network from DB container
        volumes = [
          "${hostDataDir}/config:/config"
          "${mediaDir}:/downloads"
        ];
        environment = {
          PUID = toString uid;
          PGID = toString gid;
          DB_HOST = "127.0.0.1";
          DB_PORT = toString dbPort;
          DB_USER = "root";
          DB_PASSWORD = "123qweasd";
          DB_NAME = name;
        };
        extraOptions = [ "--network=container:${name}-db" ];
        dependsOn = [ "${name}-db" ];
      };

      "${name}-db" = {
        image = "mariadb:10.3";
        ports = [
          "${toString port}:${toString port}"
          "${toString dbPort}:${toString dbPort}"
        ];
        volumes = [
          "${hostDataDir}/database:/var/lib/mysql"
        ];
        environment = {
          MYSQL_ROOT_PASSWORD = "123qweasd";
          MYSQL_DATABASE = name;
        };
        cmd = [
          "--port=${toString dbPort}"
          "--character-set-server=utf8mb4"
          "--collation-server=utf8mb4_unicode_ci"
        ];
      };
    };

    users = {
      groups.${name}.gid = gid;
      users.${name} = {
        isSystemUser = true;
        group = name;
        uid = uid;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${hostDataDir}' 0775 ${name} ${name} - -"
      "d '${hostDataDir}/config' 0775 ${name} ${name} - -"
      "d '${hostDataDir}/database' 0775 999 999 - -"
      "d '${mediaDir}' 0775 ${name} ${name} - -"
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
        from = port;
        to = port;
      }
    ];

    services.nginx = {
      virtualHosts = {
        "${name}" = {
          serverName = "h001.net.joshuabell.xyz";
          listen = [
            {
              port = port;
              addr = "0.0.0.0";
            }
          ];
          locations."/" = {
            proxyWebsockets = true;
            proxyPass = "http://192.168.15.1:${toString port}";
          };
        };
      };
    };
  };
}
