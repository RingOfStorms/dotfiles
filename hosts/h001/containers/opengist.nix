{
  constants,
  ...
}:
let
  name = "opengist";
  c = constants.services.opengist;
  hostDataDir = c.dataDir;

  v_port = c.port;
in
{
  virtualisation.oci-containers.containers = {
    "${name}" = {
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
  system.activationScripts."${name}_directories" = ''
    mkdir -p ${hostDataDir}
    chown -R root:root ${hostDataDir}
    chmod -R 777 ${hostDataDir}
  '';

  services.nginx.virtualHosts."${c.domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${builtins.toString v_port}";
      };
    };
  };
}
