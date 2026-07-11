{
  constants,
  fleet,
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
  # The Podman unit is generated as `podman-opengist.service`.  Wait for the
  # network and Podman before it is started at boot; otherwise the generated
  # container start may race their initialization.  Restart failures with a
  # modest delay rather than rapidly exhausting systemd's start limit.
  systemd.services."podman-${name}" = {
    wants = [ "network-online.target" "podman.service" ];
    after = [ "network-online.target" "podman.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  system.activationScripts."${name}_directories" = ''
    mkdir -p ${hostDataDir}
    chown root:root ${hostDataDir}
    chmod 777 ${hostDataDir}
  '';

  services.nginx.virtualHosts."${c.domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
    locations = {
      "/" = {
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:${builtins.toString v_port}";
      };
    };
  };
}
