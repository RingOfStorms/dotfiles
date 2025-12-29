{ pkgs, ... }:
{
  services.nfs.server = {
    enable = true;
    exports = ''
      /data 100.64.0.0/10(rw,sync,no_subtree_check,fsid=0,crossmnt)
    '';
  };

  environment.systemPackages = [
    pkgs.nfs-utils
  ];
}
