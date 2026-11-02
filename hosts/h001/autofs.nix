{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.nfs-utils
  ];
  # h004 exports /data/nixarr as its NFSv4 root, not /data/backups.
  # Keep /nfs/h002/nixarr because arr stores absolute media paths there.
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
