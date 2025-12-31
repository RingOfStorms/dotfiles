{
  pkgs,
  config,
  lib,
  ...
}:
lib.mkMerge [
  ({
    users.groups.media = {
      gid = 2000;
    };

    # Keep exported paths group-writable for media services.
    # `2` (setgid) makes new files inherit group `media`.
    systemd.tmpfiles.rules = [
      "d /data/nixarr 2775 root media - -"
      "d /data/nixarr/media 2775 root media - -"
      "d /data/pinchflat 2775 root media - -"
      "d /data/pinchflat/media 2775 root media - -"
    ];


    services.nfs.server = {
      enable = true;
      exports = ''
        /data 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)
        /data 10.12.14.0/10(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)
      '';
    };

    environment.systemPackages = [
      pkgs.nfs-utils
    ];
  })
  # Open ports and expose so local network works
  (lib.mkIf config.networking.firewall.enable {
    services.rpcbind.enable = true;
    services.nfs.server.lockdPort = 32803;
    services.nfs.server.mountdPort = 892;
    services.nfs.server.statdPort = 662;

    networking.firewall = {
      allowedTCPPorts = [
        2049
        111
        892
        32803
        662
      ];
      allowedUDPPorts = [
        2049
        111
        892
        32803
        662
      ];
    };

  })
]
