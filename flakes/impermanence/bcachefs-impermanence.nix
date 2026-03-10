{
  config,
  utils,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib)
    mkOption
    mkIf
    mkMerge
    types
    ;
  cfg = config.ringofstorms.impermanence;

  primaryDeviceUnit = "${utils.escapeSystemdPath cfg.disk.primary}.device";

  # ── Impermanence tools (gc, ls, diff) ────────────────────────────────────
  persistence = config.environment.persistence or { };

  normalizePath = v:
    if builtins.isString v then
      v
    else if v ? dirPath then
      v.dirPath
    else if v ? filePath then
      v.filePath
    else
      null;

  pathsFromList = f: xs: lib.filter (p: p != null) (map f xs);

  userPersistencePaths = users:
    lib.flatten (
      lib.mapAttrsToList (
        userName: userCfg:
        let
          home = (config.users.users.${userName} or { }).home or "/home/${userName}";
          normalizeUserPath = v:
            if builtins.isString v then
              if lib.hasPrefix "/" v then v else "${home}/${v}"
            else
              normalizePath v;
        in
        (pathsFromList normalizeUserPath (userCfg.directories or [ ]))
        ++ (pathsFromList normalizeUserPath (userCfg.files or [ ]))
      ) users
    );

  ignorePaths =
    lib.unique (
      lib.filter (p: p != null && p != "" && p != "/") (
        lib.flatten (
          lib.mapAttrsToList (
            persistRoot: persistCfg:
            [ persistRoot ]
            ++ (pathsFromList normalizePath (persistCfg.directories or [ ]))
            ++ (pathsFromList normalizePath (persistCfg.files or [ ]))
            ++ (userPersistencePaths (persistCfg.users or { }))
          ) persistence
        )
      )
    );

  ignoreFile = pkgs.writeText "bcache-impermanence-ignore-paths" (
    lib.concatStringsSep "\n" ignorePaths + "\n"
  );

  scriptFile = pkgs.writeText "bcache-impermanence.sh" (
    builtins.readFile ./impermanence-tools.sh
  );

  bcacheImpermanenceBin = pkgs.writeShellScriptBin "bcache-impermanence" ''
    export BCACHE_IMPERMANENCE_IGNORE_FILE="${ignoreFile}"
    exec ${pkgs.bash}/bin/bash "${scriptFile}" "$@"
  '';
in
{
  options.ringofstorms.impermanence = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable bcachefs impermanence with subvolume layout and boot-time root reset.";
    };

    disk = {
      boot = mkOption {
        type = types.str;
        description = "Device path for the EFI boot partition (e.g. /dev/disk/by-uuid/...).";
      };
      primary = mkOption {
        type = types.str;
        description = "Device path for the primary bcachefs partition (e.g. /dev/disk/by-uuid/...).";
      };
      swap = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Device path for the swap partition, or null to disable swap.";
      };
    };

    encrypted = mkOption {
      type = types.bool;
      default = true;
      description = "Whether the bcachefs partition is encrypted and needs unlocking at boot.";
    };

    usbKey = mkOption {
      type = types.bool;
      default = false;
      description = "Scan USB block devices for a bcachefs filesystem containing a 'key' file to auto-unlock the primary partition. Falls back to passphrase if no key is found.";
    };

    usbKeyPassword = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Optional passphrase for encrypted USB key drives. When set, the unlock
        service will attempt to unlock bcachefs USB devices with this passphrase
        before mounting them. Unencrypted USB drives are still tried first.
        This is a publicly-known secret -- it only prevents trivial exposure of
        the key file if the USB drive is physically lost.
      '';
    };

    snapshotRoot = mkOption {
      type = types.str;
      default = "/.snapshots/old_roots";
      description = "Directory where old root snapshots are stored.";
    };

    gc = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable garbage collection of old root snapshots.";
      };
      keepRecentCount = mkOption {
        type = types.int;
        default = 5;
        description = "Always keep at least this many most recent snapshots.";
      };
      keepRecentWeeks = mkOption {
        type = types.int;
        default = 4;
        description = "Keep at least one snapshot per ISO week within this many recent weeks.";
      };
      keepPerMonth = mkOption {
        type = types.int;
        default = 1;
        description = "Keep at least this many snapshots per calendar month (latest ones).";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # ── Filesystem mounts ──────────────────────────────────────────────────
    {
      fileSystems."/boot" = {
        device = cfg.disk.boot;
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };

      fileSystems."/" = {
        device = cfg.disk.primary;
        fsType = "bcachefs";
        options = [
          "X-mount.subdir=@root"
        ];
      };
      fileSystems."/nix" = {
        device = cfg.disk.primary;
        fsType = "bcachefs";
        options = [
          "X-mount.mkdir"
          "X-mount.subdir=@nix"
          "relatime"
        ];
      };
      fileSystems."/.snapshots" = {
        device = cfg.disk.primary;
        fsType = "bcachefs";
        options = [
          "X-mount.mkdir"
          "X-mount.subdir=@snapshots"
          "relatime"
        ];
      };
      fileSystems."/persist" = {
        device = cfg.disk.primary;
        fsType = "bcachefs";
        options = [
          "X-mount.mkdir"
          "X-mount.subdir=@persist"
        ];
        neededForBoot = true;
      };
    }

    # ── Swap ───────────────────────────────────────────────────────────────
    (mkIf (cfg.disk.swap != null) {
      swapDevices = [ { device = cfg.disk.swap; } ];
    })

    # ── Disable bcachefs per-mount unlock prompts ──────────────────────────
    (
      let
        disableFs = fs: {
          name = "unlock-bcachefs-${utils.escapeSystemdPath fs.mountPoint}";
          value = {
            enable = false;
          };
        };
      in
      {
        boot.initrd.systemd.enable = true;
        systemd.services =
          let
            isSystemdNonBootBcache = fs: (fs.fsType == "bcachefs") && (!utils.fsNeededForBoot fs);
            bcacheNonBoots = lib.filterAttrs (k: fs: isSystemdNonBootBcache fs) config.fileSystems;
          in
          (lib.mapAttrs' (k: disableFs) bcacheNonBoots);
        boot.initrd.systemd.services =
          let
            isSystemdBootBcache = fs: (fs.fsType == "bcachefs") && (utils.fsNeededForBoot fs);
            bcacheBoots = lib.filterAttrs (k: fs: isSystemdBootBcache fs) config.fileSystems;
          in
          (lib.mapAttrs' (k: disableFs) bcacheBoots);
      }
    )

    # ── Boot ordering fix for impermanence + custom unlock ─────────────────
    (mkIf cfg.encrypted {
      boot.initrd.systemd.services.create-needed-for-boot-dirs = {
        after = [
          "bcachefs-reset-root.service"
          "unlock-bcachefs-custom.service"
        ];
        requires = [
          "bcachefs-reset-root.service"
          "unlock-bcachefs-custom.service"
        ];
        serviceConfig.KeyringMode = "shared";
      };
    })

    # ── Root reset (snapshot + delete + recreate on every boot) ─────────────
    {
      boot.initrd.systemd.services.bcachefs-reset-root = {
        description = "Reset bcachefs root subvolume before pivot";

        after = [
          "initrd-root-device.target"
          "cryptsetup.target"
        ] ++ lib.optionals cfg.encrypted [
          "unlock-bcachefs-custom.service"
        ];

        requires = [
          primaryDeviceUnit
        ] ++ lib.optionals cfg.encrypted [
          "unlock-bcachefs-custom.service"
        ];

        before = [
          "sysroot.mount"
        ];
        wantedBy = [
          "initrd-root-fs.target"
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          KeyringMode = "shared";
        };

        script = ''
          cleanup() {
              if [[ ! -e /primary_tmp/@root ]]; then
                  echo "Cleanup: Creating new @root"
                  bcachefs subvolume create /primary_tmp/@root
              fi
              echo "Cleanup: Unmounting /primary_tmp"
              umount /primary_tmp || true
          }
          trap cleanup EXIT

          mkdir -p /primary_tmp

          echo "Mounting ${cfg.disk.primary}..."
          if ! mount "${cfg.disk.primary}" /primary_tmp; then
              echo "Mount failed. Cannot reset root."
              exit 1
          fi

          if [[ -e /primary_tmp/@root ]]; then
              mkdir -p /primary_tmp/@snapshots/old_roots

              # Use safe timestamp format (dashes instead of colons)
              timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
              snap="/primary_tmp/@snapshots/old_roots/$timestamp"
              echo "Snapshotting @root to $snap"
              bcachefs subvolume snapshot /primary_tmp/@root "$snap"

              echo "Deleting current @root"
              bcachefs subvolume delete /primary_tmp/@root
          fi

          # Trap handles creating new root and unmount
        '';
      };
    }

    # ── Encryption unlock service ──────────────────────────────────────────
    (mkIf cfg.encrypted {
      boot.supportedFilesystems = [
        "bcachefs"
      ];

      boot.initrd.systemd.services.unlock-bcachefs-custom = {
        description = "Custom bcachefs unlock (USB key optional, passphrase retry)";

        wantedBy = [
          "persist.mount"
          "sysroot.mount"
          "initrd-root-fs.target"
        ];
        before = [
          "persist.mount"
          "sysroot.mount"
          "initrd-root-fs.target"
        ];

        after = [
          "initrd-root-device.target"
        ];
        requires = [
          "initrd-root-device.target"
          primaryDeviceUnit
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          KeyringMode = "shared";
          StandardInput = "tty";
          StandardOutput = "tty";
          StandardError = "tty";
          TTYPath = "/dev/console";
          TTYReset = true;
          TTYVHangup = true;
          TTYVTDisallocate = true;
        };

        script =
          let
            ENABLE_USB = if cfg.usbKey then "1" else "";
            USB_KEY_PASSWORD = if cfg.usbKeyPassword != null then cfg.usbKeyPassword else "";
            PRIMARY = cfg.disk.primary;
          in
          ''
            try_mount_and_read_key() {
              local dev="$1"
              local mount_point="$2"

              # Try unencrypted mount first
              if mount -t bcachefs -o ro "$dev" "$mount_point" 2>/dev/null; then
                if [ -f "$mount_point/key" ]; then
                  return 0
                fi
                umount "$mount_point" || true
                return 1
              fi

              # If a USB key password is configured, try unlocking encrypted drives
              if [[ -n "${USB_KEY_PASSWORD}" ]]; then
                echo "Attempting encrypted unlock of $dev..."
                echo -n "${USB_KEY_PASSWORD}" > /tmp/usb_key_passphrase
                if ${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /tmp/usb_key_passphrase "$dev" 2>/dev/null; then
                  rm -f /tmp/usb_key_passphrase
                  if mount -t bcachefs -o ro "$dev" "$mount_point" 2>/dev/null; then
                    if [ -f "$mount_point/key" ]; then
                      return 0
                    fi
                    umount "$mount_point" || true
                    return 1
                  fi
                fi
                rm -f /tmp/usb_key_passphrase
              fi

              return 1
            }

            unlock_with_usb_key() {
              if [[ -z "${ENABLE_USB}" ]]; then
                return 2
              fi

              echo "Scanning for USB unlock key (bcachefs with /key file)..."
              mkdir -p /tmp/usb_key_mount

              # Wait up to 4 seconds for USB devices to appear
              for attempt in {1..40}; do
                for dev in /dev/sd*; do
                  # Only try whole-disk devices and partitions that are block devices
                  [ -b "$dev" ] || continue

                  # Skip if already the primary device
                  real_primary="$(readlink -f "${PRIMARY}" 2>/dev/null || echo "${PRIMARY}")"
                  real_dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
                  [ "$real_dev" = "$real_primary" ] && continue

                  if try_mount_and_read_key "$dev" /tmp/usb_key_mount; then
                    echo "Found key on $dev. Attempting unlock..."
                    if ${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /tmp/usb_key_mount/key "${PRIMARY}"; then
                      umount /tmp/usb_key_mount || true
                      echo "Bcachefs unlock successful (USB key on $dev)!"
                      return 0
                    fi
                    echo "Key on $dev failed to unlock."
                    umount /tmp/usb_key_mount || true
                  fi
                done
                sleep 0.1
              done

              echo "No USB key found within timeout."
              return 2
            }

            unlock_with_passphrase_until_success() {
              echo "Unlocking ${PRIMARY} (will retry on failure)..."
              while true; do
                if ${pkgs.bcachefs-tools}/bin/bcachefs unlock "${PRIMARY}"; then
                  echo "Bcachefs unlock successful (passphrase)!"
                  return 0
                fi
                echo "Unlock failed. Try again."
                sleep 0.2
              done
            }

            # 1) Optional USB key scan (if enabled)
            if unlock_with_usb_key; then
              exit 0
            fi

            # 2) Fall back to passphrase with retry
            unlock_with_passphrase_until_success
          '';
      };
    })

    # ── Impermanence tools CLI + GC service ────────────────────────────────
    {
      environment.systemPackages = [
        bcacheImpermanenceBin
        pkgs.coreutils
        pkgs.findutils
        pkgs.diffutils
        pkgs.bcachefs-tools
        pkgs.fzf
      ];
    }

    (mkIf cfg.gc.enable {
      systemd.services."bcache-impermanence-gc" = {
        description = "Garbage collect bcachefs impermanence snapshots";
        wantedBy = [ "multi-user.target" ];
        after = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          exec ${bcacheImpermanenceBin}/bin/bcache-impermanence gc \
            --snapshot-root ${cfg.snapshotRoot} \
            --keep-per-month ${toString cfg.gc.keepPerMonth} \
            --keep-recent-weeks ${toString cfg.gc.keepRecentWeeks} \
            --keep-recent-count ${toString cfg.gc.keepRecentCount}
        '';
      };
    })
  ]);
}
