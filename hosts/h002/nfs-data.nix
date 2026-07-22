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
      # Export the Bcachefs mount itself, not /. If /data cannot mount, NFS has
      # no usable export rather than exposing the empty /data mountpoint on the
      # root filesystem to media clients.
      exports = ''
        /data 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0)
        /data 10.12.14.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0)
      '';
    };

    # Do not bring NFS up unless the actual Bcachefs media filesystem mounted.
    systemd.services.nfs-server = {
      requires = [ "data.mount" ];
      after = [ "data.mount" ];
      unitConfig.RequiresMountsFor = "/data";
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
