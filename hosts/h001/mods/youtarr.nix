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
  hostConfigDir = "/var/lib/${name}";
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
          "${hostConfigDir}:/config"
          "${mediaDir}:/downloads"
        ];
        environment = {
          PUID = toString uid;
          PGID = toString gid;
        };
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
      "d '${hostConfigDir}' 0775 ${name} ${name} - -"
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
