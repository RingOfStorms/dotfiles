{
  pkgs,
  config,
  lib,
  constants,
  ...
}:
let
  nfs = constants.services.nfs;
in
lib.mkMerge [
  ({
    services.nfs.server = {
      enable = true;
      exports = ''
        ${nfs.exportRoot} 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)
        ${nfs.exportRoot} 10.12.14.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)
      '';
    };

    environment.systemPackages = [
      pkgs.nfs-utils
    ];
  })
  # Open ports and expose so local network works
  (lib.mkIf config.networking.firewall.enable {
    services.rpcbind.enable = true;
    services.nfs.server.lockdPort = nfs.lockdPort;
    services.nfs.server.mountdPort = nfs.mountdPort;
    services.nfs.server.statdPort = nfs.statdPort;

    networking.firewall = {
      allowedTCPPorts = [
        nfs.nfsPort
        nfs.rpcbindPort
        nfs.mountdPort
        nfs.lockdPort
        nfs.statdPort
      ];
      allowedUDPPorts = [
        nfs.nfsPort
        nfs.rpcbindPort
        nfs.mountdPort
        nfs.lockdPort
        nfs.statdPort
      ];
    };

  })
]
