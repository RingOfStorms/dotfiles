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

  USB_KEY = null;

  IMPERMANENCE = true;

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
  {
    # Impermanence fix for working with custom unlock and reset with root bcache
    boot.initrd.systemd.services.create-needed-for-boot-dirs = {
      after = [
        "unlock-bcachefs-custom.service"
        "bcachefs-reset-root.service"
      ];
      requires = [
        "unlock-bcachefs-custom.service"
        "bcachefs-reset-root.service"
      ];
      serviceConfig.KeyringMode = "shared";
    };
  }
  # Bcachefs auto decryption
  (lib.mkIf (USB_KEY != null) {
    boot.supportedFilesystems = [
      "bcachefs"
    ];

    boot.initrd.systemd.services.unlock-bcachefs-custom = {
      description = "Custom single bcachefs unlock for all subvolumes";

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
      };

      script = ''
        echo "Searching for USB Unlock Key..."
        KEY_FOUND=0
        # 4 second search
        for i in {1..40}; do
          if [ -e "${USB_KEY}" ]; then
            KEY_FOUND=1
            break
          fi
          sleep 0.1
        done

        if [ "$KEY_FOUND" -eq 1 ]; then
            echo "USB Key found at ${USB_KEY}. Attempting unlock..."
            mkdir -p /tmp/usb_key_mount
            
            # Mount read-only
            if mount -t bcachefs -o ro "${USB_KEY}" /tmp/usb_key_mount; then
                # Attempt unlock
                ${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /tmp/usb_key_mount/key "${PRIMARY}"
                UNLOCK_STATUS=$?
                
                # Cleanup
                umount /tmp/usb_key_mount
                
                if [ $UNLOCK_STATUS -eq 0 ]; then
                    echo "Bcachefs unlock successful!"
                    exit 0
                else
                    echo "Failed to unlock with USB key."
                fi
            else
                echo "Failed to mount USB key device."
            fi
        else
            echo "USB Key not found within timeout."
        fi

        # 3. Fallback
        echo "Proceeding to standard mount (password prompt will appear if still locked)..."
        exit 0
      '';
    };
  })
  (lib.mkIf IMPERMANENCE {
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
        "sysroot.mount"
        "initrd.target"
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
]
