{ constants, ... }:
{
  ringofstorms.containers = {
    enable = true;
    # nginx (:80/:443 internal, :8443 edge), the edge-peer drop on the
    # internal listener and the pushed cert are host-module defaults.
    nginx.acl.lan = [ "10.12.14.0/24" ];
    # Hand-written vhosts in mods/arr-nginx.nix admit the whole tailnet.
    # Placement-driven routes use runtime sets instead.
    nginx.extraWebSources = [
      "100.64.0.0/10"
      "fd7a:115c:a1e0::/48"
    ];
    # Shares the repository and schedule with mods/restic-backup.nix;
    # sec-agent.nix supplies environmentFile for both jobs.
    backup = {
      enable = true;
      schedule = "03:00";
    };
    privateNetwork.enable = true;
    # Checked by `containers deploy/move` against service.nix `requires`.
    capabilities = [
      "nfs-h004" # /nfs/h002/nixarr autofs mount of the h004 NAS (path name kept: stored in arr app state)
      "intel-qsv" # /dev/dri, 11th gen iGPU (hardware-transcoding.nix)
      "bulk" # /srv/bulk: the 10T WD disk (immich, paperless media)
    ];
    # The media stack only runs while the NAS is reachable: take h004 down
    # and `arr` stops within ~a minute; bring it back and the guard starts
    # `arr` again (unless it was stopped with `containers stop arr`).
    # h004 creates the sentinel (/data/nixarr/.h004-online) whenever its NFS
    # server starts (hosts/h004/nfs-data.nix). /nfs/h002/nixarr is the autofs
    # mount of h004's only export (/data/nixarr, not all of /data).
    guards.h004 = {
      mounts = [
        {
          path = "/nfs/h002/nixarr";
          sentinel = "/nfs/h002/nixarr/.h004-online";
        }
      ];
      units.${constants.services.nixarr.containerName} =
        "container@${constants.services.nixarr.containerName}.service";
    };
  };
}
