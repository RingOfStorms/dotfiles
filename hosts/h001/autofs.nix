{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.nfs-utils
  ];
  # C2: h004 exports only /data/nixarr (hosts/h004/nfs-data.nix, fsid=0), so
  # its NFSv4 root is mounted at /nfs/h002/nixarr. The arr apps' stored paths
  # (/nfs/h002/nixarr/media/...) stay the same; /data/backups is not exported.
  # /nfs/h002 itself is the autofs indirect mount point.
  services.autofs = {
    enable = true;
    autoMaster =
      let
        conf = pkgs.writeText "nfs-h002" ''
          nixarr -fstype=nfs4,rw,nofail,nfsvers=4 10.12.14.184:/
        '';
      in
      ''
        /nfs/h002 file:${conf}
      '';
  };
}
