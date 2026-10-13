# h001 as a floating-container host (containers/README.md).
{ constants, ... }:
{
  # litellm (containers/litellm) binds 0.0.0.0:8094 on the host network; other
  # hosts reach it over the tailnet only.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8094 ];

  ringofstorms.containers = {
    enable = true;
    # Runtime vhosts from service.nix `nginx` blocks (e.g. opengist).
    nginx.enable = true;
    # Checked by `containers deploy/move` against service.nix `requires`.
    capabilities = [
      "nfs-h002" # /nfs/h002 autofs mount of the NAS
      "intel-qsv" # /dev/dri, 11th gen iGPU (hardware-transcoding.nix)
    ];
    # The media stack only runs while the NAS is reachable: take h002 down
    # and `arr` stops within ~a minute; bring it back and the guard starts
    # `arr` again (unless it was stopped with `containers stop arr`).
    # Create the sentinel once on h002: touch /data/.h002-online
    guards.h002 = {
      mounts = [
        {
          path = "/nfs/h002";
          sentinel = "/nfs/h002/.h002-online";
        }
      ];
      units.${constants.services.nixarr.containerName} =
        "container@${constants.services.nixarr.containerName}.service";
    };
  };
}
