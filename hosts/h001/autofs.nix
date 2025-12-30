{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.nfs-utils
  ];
  services.autofs = {
    enable = true;
    autoMaster =
      let
        conf = pkgs.writeText "nfs" ''
          h002 -fstype=nfs4,rw,nofail,nfsvers=4 10.12.14.183:/
        '';
      in
      ''
        /nfs file:${conf}
      '';
  };
}
