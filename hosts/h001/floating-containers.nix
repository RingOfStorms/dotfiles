# h001 as a floating-container host (containers/README.md).
{ constants, ... }:
{
  # litellm (containers/litellm) is on 127.0.0.1:8094 behind the tailnet
  # vhost litellm.joshuabell.xyz; no raw port to open.

  ringofstorms.containers = {
    enable = true;
    # Runtime vhosts from service.nix `nginx` blocks (e.g. opengist).
    nginx.enable = true;
    # Checked by `containers deploy/move` against service.nix `requires`.
    capabilities = [
      "nfs-h004" # /nfs/h002 autofs mount of the h004 NAS (path name kept: stored in arr app state)
      "intel-qsv" # /dev/dri, 11th gen iGPU (hardware-transcoding.nix)
      "wd10" # /drives/wd10 local 10T ext4 (immich, paperless media)
    ];
    # The media stack only runs while the NAS is reachable: take h004 down
    # and `arr` stops within ~a minute; bring it back and the guard starts
    # `arr` again (unless it was stopped with `containers stop arr`).
    # Create the sentinel once on h004: touch /data/.h004-online
    guards.h004 = {
      mounts = [
        {
          path = "/nfs/h002";
          sentinel = "/nfs/h002/.h004-online";
        }
      ];
      units.${constants.services.nixarr.containerName} =
        "container@${constants.services.nixarr.containerName}.service";
    };
  };
}
