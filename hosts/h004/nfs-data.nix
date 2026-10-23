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
  # C2 (closed): root_squash is now enabled below. /data/backups was moved
  # into its own bcachefs subvolume (mode 0700 luser:users), but that
  # subvolume still shares the SAME superblock (same bcachefs filesystem,
  # same st_dev) as /data/nixarr -- bcachefs subvolumes are not separate
  # mounts/fsids at the VFS level, they are just separate dentry subtrees
  # of one super_block. In fs/bcachefs/fs.c, bch2_encode_fh() packs
  # { inode, subvol, generation } into the NFS filehandle and
  # bch2_nfs_get_inode() resolves `subvol` by looking it up within that
  # *same* superblock, so a filehandle naming an inode in the backups
  # subvolume is structurally just as "valid" to the filesystem as one
  # naming an inode under /data/nixarr -- there is no wrong-fsid rejection
  # to rely on here (unlike a genuinely separate mount/export).
  # The actual barrier against a forged/guessed handle for /data/backups
  # reaching nfsd through the /data/nixarr export is `subtree_check`
  # (NOT `no_subtree_check`, which was the bug): in fs/nfsd/nfsfh.c,
  # nfsd_acceptable() walks `dget_parent()` from the target dentry up to
  # exp->ex_path.dentry (/data/nixarr) on every fh_verify(), and returns
  # ESTALE/NFS4ERR_STALE if that walk never reaches the export root --
  # which is exactly what happens for any dentry under the sibling
  # /data/backups subvolume. With `no_subtree_check` that ancestor walk is
  # skipped entirely, so nfsd fell back to only checking inode
  # permissions, and an AUTH_SYS client asserting uid 1000/gid 100
  # (matching backups' 0700 luser:users owner) could use a forged handle
  # to read it straight through the /data/nixarr export -- confirmed live
  # 2026-10-22 (see ideas/security_remediation_plan_2026-10-22.md, C2):
  # splicing the real f_handle bytes of /data/backups/.c2-canary-test into
  # a valid /data/nixarr wire filehandle and calling open_by_handle_at()
  # from h001 as uid 1000 succeeded and read the canary's contents with
  # no_subtree_check, and failed with ESTALE once subtree_check was
  # enabled below. even a legitimate handle inside /data/nixarr can no
  # longer write/chown as uid 0 thanks to root_squash (client root is
  # mapped to the anonymous uid/gid, default nobody:nogroup). The `arr`
  # app directories under /data/nixarr/media/{library,...} are
  # pre-created with correct root:media ownership directly on h004
  # (hosts/h004/nfs-data-users-nixarr.nix), not by the NFS client, so
  # arr's own tmpfiles rules for those paths only need to find them
  # already present/correct, not chown them as root.
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
          lib.concatMapStringsSep " " (ip: "${ip}(rw,sync,subtree_check,root_squash,fsid=0)") nfsClients
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
