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

    # One-shot fixup for existing files after migrations/rsync.
    # Runs before `nfs-server` so clients always see correct perms.
    systemd.services.nfs-media-permissions = {
      description = "Fix NFS media permissions";
      after = [ "local-fs.target" ];
      before = [ "nfs-server.service" ];
      requiredBy = [ "nfs-server.service" ];
      serviceConfig.Type = "oneshot";
      path = [ pkgs.coreutils pkgs.findutils pkgs.glibc.bin ];
      script = ''
        set -euo pipefail

        getent group media >/dev/null

        for dir in /data/nixarr/media /data/pinchflat/media; do
          mkdir -p "$dir"
          chgrp -R media "$dir"
          chmod -R g+rwX "$dir"
          find "$dir" -type d -exec chmod 2775 {} +
        done
      '';
    };

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
