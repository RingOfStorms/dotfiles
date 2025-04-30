{
  ...
}:
let
  name = "opengist";
  hostDataDir = "/var/lib/${name}";

  v_port = 6157;
in
{
  virtualisation.oci-containers.containers = {
    opengist = {
      user = "root";
      image = "ghcr.io/thomiceli/opengist:1";
      ports = [
        "127.0.0.1:${toString v_port}:${toString v_port}"
      ];
      volumes = [
        "${hostDataDir}:/opengist"
      ];
      environment = {
        OG_LOG_LEVEL = "info";
      };
    };
  };

  services.nginx.virtualHosts."gist.joshuabell.xyz" = {
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${builtins.toString v_port}";
      };
    };
  };
}
