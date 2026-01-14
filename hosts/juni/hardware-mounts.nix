{
  config,
  utils,
  pkgs,
  lib,
  ...
}:
let
  BOOT = "/dev/disk/by-uuid/F5C0-5585";
  PRIMARY = "/dev/disk/by-uuid/3bfd6e57-5e0f-4742-99e3-e69891ae2431";

  SWAP = "/dev/disk/by-uuid/ad0311e2-7eb1-47af-bc4b-6311968cbccf";

  IMPERMANENCE = true;
  ENCRYPTED = true;

  USB_KEY = null;

  primaryDeviceUnit = "${utils.escapeSystemdPath PRIMARY}.device";
in
lib.mkMerge [
  # Main filesystems
  {
    # BOOT
    fileSystems."/boot" = {
      device = BOOT;
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };

    # PRIMARY
    fileSystems."/" = {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "X-mount.subdir=@root"
      ];
    };
    fileSystems."/nix" = {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "X-mount.mkdir"
        "X-mount.subdir=@nix"
        "relatime"
      ];
    };
    fileSystems."/.snapshots" = {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "X-mount.mkdir"
        "X-mount.subdir=@snapshots"
        "relatime"
      ];
    };
    fileSystems."/persist" = lib.mkIf IMPERMANENCE {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "X-mount.mkdir"
        "X-mount.subdir=@persist"
      ];
      neededForBoot = true; # NOTE for impermanence only
    };
  }
  (lib.mkIf (SWAP != null) { swapDevices = [ { device = SWAP; } ]; })
  # Disable bcachefs built in password prompts for all mounts (which asks for every single subdir mount above
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
  (lib.mkIf IMPERMANENCE {
    # Impermanence fix for working with custom unlock and reset with root bcache
    boot.initrd.systemd.services.create-needed-for-boot-dirs = lib.mkIf ENCRYPTED {
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

    # Resets my root to a fresh snapshot. I do this my simply moving root to an old snapshots directory
    boot.initrd.systemd.services.bcachefs-reset-root = {
      description = "Reset bcachefs root subvolume before pivot";

      after = [
        "initrd-root-device.target"
        "cryptsetup.target"
        "unlock-bcachefs-custom.service"
      ];

      requires = [
        primaryDeviceUnit
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

        echo "Mounting ${PRIMARY}..."
        if ! mount "${PRIMARY}" /primary_tmp; then
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
  })
  # Bcachefs auto decryption / unlock (will use usb key if provided above, else just prompts password)
  # We use this for password instead of the default one because default doesn't let you retry if you misstype the password
  (lib.mkIf ENCRYPTED {
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
        KeyringMode = lib.mkIf IMPERMANENCE "shared";
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
          USB_KEY_PATH = if USB_KEY == null then "" else USB_KEY;
        in
        ''
          unlock_with_usb_key() {
            if [[ -z "${USB_KEY_PATH}" ]]; then
              return 2
            fi

            echo "Searching for USB unlock key..."
            KEY_FOUND=0
            # 4 second search
            for i in {1..40}; do
              if [ -e "${USB_KEY_PATH}" ]; then
                KEY_FOUND=1
                break
              fi
              sleep 0.1
            done

            if [ "$KEY_FOUND" -ne 1 ]; then
              echo "USB key not found within timeout."
              return 2
            fi

            echo "USB key found at ${USB_KEY_PATH}. Attempting unlock..."
            mkdir -p /tmp/usb_key_mount

            # Mount read-only
            if ! mount -t bcachefs -o ro "${USB_KEY_PATH}" /tmp/usb_key_mount; then
              echo "Failed to mount USB key device."
              return 1
            fi

            if ${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /tmp/usb_key_mount/key "${PRIMARY}"; then
              umount /tmp/usb_key_mount || true
              echo "Bcachefs unlock successful (USB key)!"
              return 0
            fi

            umount /tmp/usb_key_mount || true
            echo "Failed to unlock with USB key."
            return 1
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

          # 1) Optional USB key unlock attempt (if configured)
          if unlock_with_usb_key; then
            exit 0
          fi

          # 2) If USB key not configured or failed, prompt for passphrase and retry
          unlock_with_passphrase_until_success
        '';
    };
  })
]
