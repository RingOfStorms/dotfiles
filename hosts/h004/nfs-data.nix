{
  pkgs,
  config,
  lib,
  constants,
  ...
}:
let
  nfs = constants.services.nfs;
  fleet = import ../fleet.nix;
  # Only h001 mounts the NAS (hosts/h001/autofs.nix -> 10.12.14.184:/, for
  # the arr container's nfs-h004 requirement). backup.nix pushes over ssh
  # (rsync), not NFS. Add a host here only when it really mounts the export.
  # C2: export only the arr tree (/data/nixarr, holding media), not all of
  # /data (backups, pinchflat, ...). h001 (hosts/h001/autofs.nix) mounts
  # 10.12.14.184:/ at /nfs/h002/nixarr, so the /nfs/h002/nixarr/media
  # paths stored in the arr apps don't change. The guard sentinel is now
  # /data/nixarr/.h004-online (created below).
  # Caveat: /data/nixarr is a directory on the same bcachefs filesystem, and
  # no_subtree_check + no_root_squash means a malicious root client that
  # forges file handles could still get outside it. That is far harder than
  # mounting `/` and reading backups/, but the real boundary is backups on
  # another filesystem (or exported subvolumes).
  exportRoot = nfs.exportRoot;

  nfsClients = [
    fleet.hosts.h001.lanIp
    fleet.hosts.h001.overlayIp
  ];
  nfsPorts = lib.concatMapStringsSep ", " toString [
    nfs.nfsPort
    nfs.rpcbindPort
    nfs.mountdPort
    nfs.lockdPort
    nfs.statdPort
  ];
in
lib.mkMerge [
  ({
    services.nfs.server = {
      enable = true;
      # Export the Bcachefs mount itself, not /. If /data cannot mount, NFS has
      # no usable export rather than exposing the empty /data mountpoint on the
      # root filesystem to media clients.
      exports = ''
        ${exportRoot} ${
          lib.concatMapStringsSep " " (ip: "${ip}(rw,sync,no_subtree_check,no_root_squash,fsid=0)") nfsClients
        }
      '';
    };

    # Do not bring NFS up unless the actual Bcachefs media filesystem mounted.
    systemd.services.nfs-server = {
      requires = [ "data.mount" ];
      after = [ "data.mount" ];
      unitConfig.RequiresMountsFor = "/data";
      # h001 guard sentinel (hosts/h001/floating-containers.nix): present
      # only while the pool is mounted, so arr stops when it is not.
      serviceConfig.ExecStartPre = [
        "${pkgs.coreutils}/bin/touch ${exportRoot}/.h004-online"
      ];
    };

    environment.systemPackages = [
      pkgs.nfs-utils
    ];
  })
  # NFS ports only from the NFS clients (not the whole LAN/tailnet).
  (lib.mkIf config.networking.firewall.enable {
    services.rpcbind.enable = true;
    services.nfs.server.lockdPort = nfs.lockdPort;
    services.nfs.server.mountdPort = nfs.mountdPort;
    services.nfs.server.statdPort = nfs.statdPort;

    networking.firewall.extraInputRules = ''
      ip saddr { ${lib.concatStringsSep ", " nfsClients} } meta l4proto { tcp, udp } th dport { ${nfsPorts} } accept comment "NFS: h001 only"
    '';

  })
]
