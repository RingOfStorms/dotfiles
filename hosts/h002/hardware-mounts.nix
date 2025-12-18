{
  utils,
  lib,
  ...
}:
let
  BOOT = "/dev/disk/by-uuid/CC65-4ADF";
  PRIMARY = "/dev/disk/by-uuid/35c8b82e-de7d-45bc-9cb2-2a422a99ee9c";

  SWAP = "/dev/disk/by-uuid/85801775-1aad-4cc8-846a-560f9f4b11f4";

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
    # (optional) for preservation/impermanence
    fileSystems."/persist" = {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "X-mount.mkdir"
        "X-mount.subdir=@persist"
      ];
      neededForBoot = true; # NOTE for impermanence only
    };
  }
  # SWAP (optional)
  { swapDevices = [ { device = SWAP; } ]; }
  {
    # Impermanence fix
    boot.initrd.systemd.services.create-needed-for-boot-dirs = {
      after = [
        "bcachefs-reset-root.service"
      ];
      requires = [
        "bcachefs-reset-root.service"
      ];
      serviceConfig.KeyringMode = "shared";
    };
  }
   # Reset root for erase your darlings/impermanence/preservation
  (lib.mkIf true {
    boot.initrd.systemd.services.bcachefs-reset-root = {
      description = "Reset bcachefs root subvolume before pivot";

      after = [
        "initrd-root-device.target"
        "cryptsetup.target"
      ];
      requires = [
        primaryDeviceUnit
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
