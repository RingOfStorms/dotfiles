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
  # Export only /data/nixarr, not the backups and other data alongside it.
  # h001 mounts this at /nfs/h002/nixarr because arr stores absolute media
  # paths there. The guard sentinel is /data/nixarr/.h004-online.
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
  # 2026-10-22 (see ideas/restic_backups.md and the bcachefs subvolume
  # fix below, C2):
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
  nfsClients6 = [ fleet.hosts.h001.overlayIp6 ];
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
          lib.concatMapStringsSep " " (ip: "${ip}(rw,sync,subtree_check,root_squash,fsid=0)") (nfsClients ++ nfsClients6)
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
      ip6 saddr { ${lib.concatStringsSep ", " nfsClients6} } meta l4proto { tcp, udp } th dport { ${nfsPorts} } accept comment "NFS: h001 only (v6)"
    '';

  })
  (
    let
      target = config.ringofstorms.backup.target;
      owner = if target.enable then "${target.owner}:${target.owner}" else "luser:users";
    in
    {
      # C2 (closed): /data/backups must be its own bcachefs subvolume, not a
      # plain directory on the same filesystem as the /data/nixarr NFS
      # export root, and must stay 0700 (owner restic:restic, uid/gid 291,
      # while the backup target is enabled; BACKUP-PLAN.md §4.3) so that
      # even a same-filesystem NFS handle-forge attempt (or an AUTH_SYS
      # request asserting an arbitrary non-root uid) can't read fleet host
      # backups. Re-asserted on every boot/activation.
      assertions = [
        {
          assertion = !target.enable || target.dataDir == "/data/backups";
          message = "hosts/h004/nfs-data.nix: ringofstorms.backup.target.dataDir must be /data/backups (the subvolume this unit owns).";
        }
      ];
      systemd.services.ensure-backups-subvolume = {
        description = "Ensure /data/backups is a bcachefs subvolume";
        after = [ "data.mount" ];
        requires = [ "data.mount" ];
        wantedBy = [ "multi-user.target" ];
        before = [
          "nfs-server.service"
        ]
        ++ lib.optionals target.enable [
          "render-htpasswd.service"
          "restic-rest-server.service"
          "fleet-backup-target-prune.service"
        ];
        requiredBy = lib.optionals target.enable [
          "restic-rest-server.service"
          "fleet-backup-target-prune.service"
        ];
        unitConfig.RequiresMountsFor = "/data";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [
          pkgs.gawk
          pkgs.findutils
        ];
        script = ''
          set -euo pipefail
          if [ ! -d /data/backups ]; then
            ${pkgs.bcachefs-tools}/bin/bcachefs subvolume create /data/backups
          elif ! ${pkgs.bcachefs-tools}/bin/bcachefs subvolume list /data | awk '{print $1}' | grep -qx backups; then
            echo "ensure-backups-subvolume: /data/backups exists but is not a bcachefs subvolume; refusing to auto-migrate live data, fix manually" >&2
            exit 1
          fi
          ${lib.optionalString target.enable ''
            # Only restic repos (svc-*) and the module's .htpasswd stub belong
            # here. Anything else (the old l001/o001 rsync trees) means the
            # §4.4 move has not run: refuse, so rest-server stays down.
            stray=$(find /data/backups -mindepth 1 -maxdepth 1 ! -name 'svc-*' ! -name .htpasswd -printf '%f ')
            if [ -n "$stray" ]; then
              echo "ensure-backups-subvolume: unexpected entries in /data/backups: $stray(run BACKUP-PLAN.md §4.4 first)" >&2
              exit 1
            fi
          ''}
          chown ${owner} /data/backups
          chmod 0700 /data/backups
        '';
      };
    }
  )
]
