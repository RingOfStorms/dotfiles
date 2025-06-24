{
  ...
}:
let
  name = "homarr";
  hostDataDir = "/var/lib/${name}";

  v_port = 7575;
in
{
  virtualisation.oci-containers.containers = {
    "${name}" = {
      image = "ghcr.io/homarr-labs/homarr:latest";
      ports = [
        "127.0.0.1:${toString v_port}:${toString v_port}"
      ];
      volumes = [
        "${hostDataDir}:/appdata"
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
      environment = {
        SECRET_ENCRYPTION_KEY = "0b7e80116a742d16a8f07452a2d9b206b1997d32a6dd2c29cfe4df676e281295";
      };
    };
  };

  system.activationScripts."${name}_directories" = ''
    mkdir -p ${hostDataDir}
    chown -R root:root ${hostDataDir}
    chmod -R 777 ${hostDataDir}
  '';
}
