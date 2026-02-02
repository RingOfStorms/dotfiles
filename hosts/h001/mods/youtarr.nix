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
        ports = [
          "${toString port}:${toString port}"
        ];
        volumes = [
          "${hostDataDir}/config:/config"
          "${mediaDir}:/downloads"
        ];
        environment = {
          PUID = toString uid;
          PGID = toString gid;
          DB_HOST = "${name}-db";
          DB_PORT = toString dbPort;
          DB_USER = "root";
          DB_PASSWORD = "123qweasd";
          DB_NAME = name;
        };
        dependsOn = [ "${name}-db" ];
      };

      "${name}-db" = {
        image = "mariadb:10.3";
        ports = [
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

    # Use Nixarr vpn
    systemd.services.podman-youtarr.vpnconfinement = {
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
