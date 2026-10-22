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

  normalizePath =
    v:
    if builtins.isString v then
      v
    else if v ? dirPath then
      v.dirPath
    else if v ? filePath then
      v.filePath
    else
      null;

  pathsFromList = f: xs: lib.filter (p: p != null) (map f xs);

  userPersistencePaths =
    users:
    lib.flatten (
      lib.mapAttrsToList (
        userName: userCfg:
        let
          home = (config.users.users.${userName} or { }).home or "/home/${userName}";
          normalizeUserPath =
            v:
            if builtins.isString v then if lib.hasPrefix "/" v then v else "${home}/${v}" else normalizePath v;
        in
        (pathsFromList normalizeUserPath (userCfg.directories or [ ]))
        ++ (pathsFromList normalizeUserPath (userCfg.files or [ ]))
      ) users
    );

  ignorePaths = lib.unique (
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

  scriptFile = pkgs.writeText "bcache-impermanence.sh" (builtins.readFile ./impermanence-tools.sh);

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
        example = "/dev/disk/by-partuuid/cd3735f2-eee9-4d03-9ae3-464a6f84941f";
        description = ''
          Swap partition, or null for no swap. It is always encrypted with a fresh
          random key every boot (no hibernation), so memory from the encrypted root
          never lands on disk in plaintext. That re-encryption overwrites the
          partition's filesystem UUID and label, so this must be a path that lives
          outside the partition: /dev/disk/by-partuuid/, by-partlabel/ or by-id/.
          by-uuid/ and by-label/ paths are rejected.
        '';
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

    # ── Swap (random key per boot) ─────────────────────────────────────────
    (mkIf (cfg.disk.swap != null) {
      assertions = [
        {
          assertion =
            !(lib.hasPrefix "/dev/disk/by-uuid/" cfg.disk.swap)
            && !(lib.hasPrefix "/dev/disk/by-label/" cfg.disk.swap);
          message = "ringofstorms.impermanence.disk.swap = ${cfg.disk.swap}: swap is re-encrypted with a random key every boot, which erases its filesystem UUID/label, so this path would vanish after the first boot. Use /dev/disk/by-partuuid/ (lsblk -no PARTUUID <dev>), by-partlabel/ or by-id/.";
        }
      ];
      swapDevices = [
        {
          device = cfg.disk.swap;
          randomEncryption.enable = true;
        }
      ];
    })

    # ── Guidance warnings ──────────────────────────────────────────────────
    {
      warnings =
        lib.optional (cfg.usbKey && cfg.usbKeyPassword == null)
          "ringofstorms.impermanence: usbKey is on but usbKeyPassword is unset, so only an unencrypted stick works and a lost stick exposes the disk passphrase. Use an encrypted stick (utilities/nixos-install-disko/usb_key.md).";
    }

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
        ]
        ++ lib.optionals cfg.encrypted [
          "unlock-bcachefs-custom.service"
        ];

        requires = [
          primaryDeviceUnit
        ]
        ++ lib.optionals cfg.encrypted [
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
          # NOTE: deliberately NO StandardInput=tty / TTYPath=/dev/console.
          # Holding /dev/console as our controlling terminal blocks
          # systemd-ask-password-console.service (the password agent) from
          # acquiring the console via TIOCSCTTY, so the prompt would never
          # render. We delegate all interactive prompting to the agent via
          # `systemd-ask-password`, which talks to it over the
          # /run/systemd/ask-password/ socket. Service stdout/stderr fall
          # through to the journal (and to the console as systemd's default
          # journal-tee in initrd).
          #
          # Bonus: this same agent-socket design is what makes the
          # prompt automatically Plymouth-compatible.
          # plymouth-ask-password-agent (enabled when
          # boot.plymouth.enable = true) listens on the same
          # /run/systemd/ask-password/ directory and renders the
          # prompt graphically via the theme's
          # display_password_callback. Don't add StandardInput=tty
          # here — it would break both the console and Plymouth flows.
        };

        script =
          let
            ENABLE_USB = if cfg.usbKey then "1" else "";
            USB_KEY_PASSWORD = if cfg.usbKeyPassword != null then cfg.usbKeyPassword else "";
            PRIMARY = cfg.disk.primary;
          in
          ''
            log() { echo "[usb-unlock] $*"; }

            try_mount_and_read_key() {
              local dev="$1"
              local mount_point="$2"

              # Check if this bcachefs device is encrypted before attempting mount,
              # because mount on an encrypted drive will block waiting for a key.
              if ${pkgs.bcachefs-tools}/bin/bcachefs unlock -c "$dev" 2>/dev/null; then
                # Device IS encrypted
                if [[ -n "${USB_KEY_PASSWORD}" ]]; then
                  log "  $dev is encrypted, trying configured password..."
                  echo -n "${USB_KEY_PASSWORD}" > /tmp/usb_key_passphrase
                  local unlock_err
                  if unlock_err=$(${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /tmp/usb_key_passphrase "$dev" 2>&1); then
                    rm -f /tmp/usb_key_passphrase
                    log "  Unlocked $dev"
                  else
                    rm -f /tmp/usb_key_passphrase
                    log "  Failed to unlock $dev: $unlock_err"
                    return 1
                  fi
                else
                  log "  $dev is encrypted but no USB key password configured, skipping"
                  return 1
                fi
              fi

              # Device is either unencrypted or was just unlocked -- mount it
              log "  Mounting $dev..."
              local mount_err
              # ro alone still allows journal replay (a write). nochanges blocks
              # every write and version_upgrade=none blocks format upgrades.
              if mount_err=$(mount -t bcachefs -o ro,nochanges,version_upgrade=none "$dev" "$mount_point" </dev/null 2>&1); then
                log "  Mounted $dev"
                if [ -f "$mount_point/key" ]; then
                  log "  Found key file on $dev"
                  return 0
                fi
                log "  No key file found on $dev, unmounting"
                umount "$mount_point" || true
                return 1
              else
                log "  Mount of $dev failed: $mount_err"
              fi

              return 1
            }

            unlock_with_usb_key() {
              if [[ -z "${ENABLE_USB}" ]]; then
                return 2
              fi

              log "Scanning for USB unlock key (bcachefs with /key file)..."
              mkdir -p /tmp/usb_key_mount

              # Resolve primary device path once outside the loop
              real_primary="$(readlink -f "${PRIMARY}" 2>/dev/null || echo "${PRIMARY}")"
              log "Primary device resolves to: $real_primary"

              # Trigger udev and wait for USB devices to settle
              udevadm trigger --subsystem-match=block
              udevadm settle --timeout=10 || true

              # Wait up to 6 seconds for USB devices to appear
              local max_wait=6
              local waited=0
              local found_any_sd=0

              while [ "$waited" -lt "$max_wait" ]; do
                # Check what block devices exist right now
                local devs_found=0
                for dev in /dev/sd*; do
                  [ -b "$dev" ] || continue
                  devs_found=1

                  # Skip the primary device
                  local real_dev
                  real_dev="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"
                  if [ "$real_dev" = "$real_primary" ]; then
                    log "Skipping $dev (is primary device)"
                    continue
                  fi

                  # Only consider USB-attached disks. SATA/SAS data drives also
                  # show up as /dev/sd*, and probing them would touch (and could
                  # replay the journal of) unrelated pools, e.g. a NAS data array.
                  local sys_path
                  sys_path="$(readlink -f "/sys/class/block/''${dev#/dev/}" 2>/dev/null || true)"
                  case "$sys_path" in
                    */usb[0-9]*/*) ;;
                    *)
                      log "Skipping $dev (not a USB device)"
                      continue
                      ;;
                  esac

                  # Skip whole-disk devices if they have partitions
                  # (e.g. skip /dev/sda if /dev/sda1 exists)
                  if [[ "$dev" =~ ^/dev/sd[a-z]+$ ]]; then
                    local has_parts=0
                    for part in "''${dev}"[0-9]*; do
                      if [ -b "$part" ]; then
                        has_parts=1
                        break
                      fi
                    done
                    if [ "$has_parts" -eq 1 ]; then
                      log "Skipping whole-disk $dev (has partitions, will try them instead)"
                      continue
                    fi
                  fi

                  found_any_sd=1
                  log "Trying device: $dev"

                  if try_mount_and_read_key "$dev" /tmp/usb_key_mount; then
                    log "Found key on $dev. Attempting to unlock primary..."
                    local primary_err
                    if primary_err=$(${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /tmp/usb_key_mount/key "${PRIMARY}" 2>&1); then
                      umount /tmp/usb_key_mount || true
                      log "Bcachefs unlock successful (USB key on $dev)!"
                      return 0
                    fi
                    log "Key on $dev failed to unlock primary: $primary_err"
                    umount /tmp/usb_key_mount || true
                  fi
                done

                if [ "$devs_found" -eq 0 ]; then
                  log "No /dev/sd* devices found yet (waited ''${waited}s)..."
                elif [ "$found_any_sd" -eq 1 ]; then
                  # We found and tried all available USB devices, no point
                  # in busy-looping. Wait a bit then do one more pass in case
                  # a slow device shows up.
                  log "Tried all available devices, waiting for new ones (''${waited}s)..."
                fi

                sleep 1
                waited=$((waited + 1))

                # Re-trigger udev every few seconds in case new devices appeared
                if [ $((waited % 3)) -eq 0 ]; then
                  udevadm trigger --subsystem-match=block 2>/dev/null || true
                  udevadm settle --timeout=3 || true
                fi
              done

              log "No USB key found within ''${max_wait}s timeout."
              log "Devices seen during scan:"
              ls -la /dev/sd* 2>/dev/null || log "  (none)"
              return 2
            }

            unlock_with_passphrase_until_success() {
              log "Falling back to passphrase unlock for ${PRIMARY}..."
              local max_attempts=3
              local attempt=1
              while [ "$attempt" -le "$max_attempts" ]; do
                # Use systemd-ask-password to render the prompt via the
                # console password agent (systemd-ask-password-console.service),
                # then pipe the result into `bcachefs unlock`. Same pattern
                # as the upstream nixpkgs bcachefs module.
                #
                # CRITICAL: this only works because our service does NOT set
                # StandardInput=tty / TTYPath=/dev/console (see serviceConfig
                # comment above). If our service held /dev/console as a ctty,
                # the agent would block forever trying to TIOCSCTTY it and
                # no prompt would ever render.
                #
                # We can't let `bcachefs unlock` prompt by itself either: its
                # prompting paths read from inherited fd 0 (here /dev/null)
                # and have an internal 3-attempt loop that misbehaves on EOF.
                # Piping a single line in routes it through the well-behaved
                # `new_from_stdin` path.
                #
                # --timeout=0 = wait indefinitely for user input.
                if systemd-ask-password --timeout=0 \
                      "Enter bcachefs passphrase for ${PRIMARY} (attempt $attempt/$max_attempts):" \
                      | ${pkgs.bcachefs-tools}/bin/bcachefs unlock "${PRIMARY}"; then
                  log "Bcachefs unlock successful (passphrase)!"
                  return 0
                fi
                log "Unlock attempt $attempt/$max_attempts failed."
                attempt=$((attempt + 1))
                sleep 1
              done

              log "Exceeded $max_attempts unlock attempts. Powering off."
              # Force an immediate poweroff from initrd. The doubled --force
              # skips even the unmount/sync attempts, which is what we want
              # from initrd where there's nothing meaningful to unmount.
              systemctl --force --force poweroff
              # Belt-and-suspenders: if systemctl is unavailable for any
              # reason, fall back to the kernel's reboot syscall via
              # /proc/sysrq-trigger ('o' = poweroff).
              echo o > /proc/sysrq-trigger 2>/dev/null || true
              exit 1
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

    # ── SSH host key ordering fix ────────────────────────────────────────
    # sshd can race ahead of the impermanence bind mounts for /etc/ssh,
    # causing it to fail to find host keys on a fresh root. Point sshd at
    # the persist paths directly and ensure the persist mount is ready.
    # See: https://github.com/nix-community/impermanence/issues/192
    {
      services.openssh.hostKeys = [
        {
          path = "/persist/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
        {
          path = "/persist/etc/ssh/ssh_host_rsa_key";
          type = "rsa";
          bits = 4096;
        }
      ];
      systemd.services.sshd = {
        after = [ "persist.mount" ];
        unitConfig.RequiresMountsFor = "/persist";
      };
    }

    # ── Fix /var/run symlink ──────────────────────────────────────────────
    # On a fresh root, /var/run may be created as a real directory before
    # NixOS activation gets to create the expected /var/run -> /run symlink.
    # Many services (e.g. automatic-timezoned) expect /var/run/dbus/... to
    # resolve to /run/dbus/.... This ensures /var/run is always a symlink.
    {
      systemd.services.fix-var-run-symlink = {
        description = "Ensure /var/run is a symlink to /run";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "dbus.socket"
          "dbus.service"
        ];
        after = [ "local-fs.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "fix-var-run" ''
            if [ -d /var/run ] && [ ! -L /var/run ]; then
              # Move any existing contents into /run
              ${pkgs.coreutils}/bin/cp -a /var/run/. /run/ 2>/dev/null || true
              ${pkgs.coreutils}/bin/rm -rf /var/run
              ${pkgs.coreutils}/bin/ln -sfn /run /var/run
            elif [ ! -e /var/run ]; then
              ${pkgs.coreutils}/bin/ln -sfn /run /var/run
            fi
          '';
        };
      };
    }

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
