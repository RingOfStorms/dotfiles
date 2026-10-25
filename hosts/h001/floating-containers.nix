# h001 as a floating-container host (containers/README.md).
{ constants, ... }:
{
  # litellm (containers/litellm) is on 127.0.0.1:8094 behind the tailnet
  # vhost litellm.joshuabell.xyz; no raw port to open.

  ringofstorms.containers = {
    enable = true;
    # Runtime vhosts from service.nix `nginx` blocks (e.g. opengist).
    nginx.enable = true;
    # o002 proxies public routes to the :8443 edge listener; drop it on the
    # internal :80/:443 listener (ROUTING-PLAN §2.3.1).
    nginx.edge.blockInternal = true;
    # LAN subnet for `exposure = "lan"` routes (nginx-acl-lan.conf).
    nginx.acl.lan = [ "10.12.14.0/24" ];
    # Internal :443 listeners use the wildcard pushed by h005
    # (hosts/_shared_assets/utilities/wildcard-cert-receiver.nix), not this host's ACME.
    nginx.tls.certDir = "/var/lib/fleet-cert/joshuabell.xyz/current";
    # Nightly restic of every service here, one snapshot per svc:<name>
    # (ROUTING-PLAN §9.1). Repo + credentials: restic_h001_env_2026-10-01
    # (sec-agent.nix configChanges sets environmentFile). Same schedule and
    # repo as the host-only job in mods/restic-backup.nix.
    backup = {
      enable = true;
      schedule = "03:00";
    };
    # Host side for service.nix net.private (ROUTING-PLAN §8 step 5): NAT,
    # DNAT for tcp/udp routes, DNS on 10.233.0.1, no container-to-container.
    privateNetwork.enable = true;
    # Checked by `containers deploy/move` against service.nix `requires`.
    capabilities = [
      "nfs-h004" # /nfs/h002/nixarr autofs mount of the h004 NAS (path name kept: stored in arr app state)
      "intel-qsv" # /dev/dri, 11th gen iGPU (hardware-transcoding.nix)
      "wd10" # /drives/wd10 local 10T ext4 (immich, paperless media)
    ];
    # The media stack only runs while the NAS is reachable: take h004 down
    # and `arr` stops within ~a minute; bring it back and the guard starts
    # `arr` again (unless it was stopped with `containers stop arr`).
    # h004 creates the sentinel (/data/nixarr/.h004-online) whenever its NFS
    # server starts (hosts/h004/nfs-data.nix). /nfs/h002/nixarr is the autofs
    # mount of h004's only export (C2: /data/nixarr, not all of /data).
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
