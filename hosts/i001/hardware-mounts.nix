{
  config,
  utils,
  pkgs,
  lib,
  ...
}:
let
  BOOT = "/dev/disk/by-uuid/9D7E-62B8";
  PRIMARY = "/dev/disk/by-uuid/2a5b6a62-08b5-491b-917b-2e07f919d584";

  SWAP = "/dev/disk/by-uuid/f12c9e5e-a32d-417f-b9d3-8beb9a3ad802";

  USB_KEY = "/dev/disk/by-uuid/63a7bd87-d644-43ea-83ba-547c03012fb6";

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
        "fmask=0022"
        "dmask=0022"
      ];
    };

    # PRIMARY
    fileSystems."/" = {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "X-mount.subdir=@root"
        # "x-systemd.requires=unlock-bcachefs-custom.service"
        # "x-systemd.after=unlock-bcachefs-custom.service"
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
    };
  }
  # SWAP (optional)
  { swapDevices = [ { device = SWAP; } ]; }
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

      # https://github.com/NixOS/nixpkgs/blob/6cdf2f456a57164282ede1c97fc5532d9dba1ee0/nixos/modules/tasks/filesystems/bcachefs.nix#L254-L259
      systemd.services =
        let
          isSystemdNonBootBcache = fs: (fs.fsType == "bcachefs") && (!utils.fsNeededForBoot fs);
          bcacheNonBoots = lib.filterAttrs (k: fs: isSystemdNonBootBcache fs) config.fileSystems;
        in
        (lib.mapAttrs' (k: disableFs) bcacheNonBoots);
      # The above auto generates these...
      # {
      #   "unlock-bcachefs-${escapeSystemdPath "/.old_roots"}".enable = false;
      #   "unlock-bcachefs-${escapeSystemdPath "/.snapshots"}".enable = false;
      #   "unlock-bcachefs-${escapeSystemdPath "/.swap"}".enable = false;
      #   "unlock-bcachefs-${escapeSystemdPath "/persist"}".enable = false;
      # };

      # https://github.com/NixOS/nixpkgs/blob/6cdf2f456a57164282ede1c97fc5532d9dba1ee0/nixos/modules/tasks/filesystems/bcachefs.nix#L291
      boot.initrd.systemd.services =
        let
          isSystemdBootBcache = fs: (fs.fsType == "bcachefs") && (utils.fsNeededForBoot fs);
          bcacheBoots = lib.filterAttrs (k: fs: isSystemdBootBcache fs) config.fileSystems;
        in
        (lib.mapAttrs' (k: disableFs) bcacheBoots);
      # same with that above
      # {
      #   "unlock-bcachefs-${escapeSystemdPath "/sysroot"}".enable = false;
      #   "unlock-bcachefs-${escapeSystemdPath "/"}".enable = false;
      #   "unlock-bcachefs-${escapeSystemdPath "/nix"}".enable = false;
      # };
    }
  )
  # Bcachefs auto decryption
  {
    boot.supportedFilesystems = [
      "bcachefs"
    ];

    # From a USB key # NOTE this method does work but if you want to boot w/o
    # and get prompted it takes 30 seconds to fail
    # boot.initrd.systemd.mounts = [
    #   {
    #     what = USB_KEY;
    #     type = "bcachefs";
    #     where = "/usb_key";
    #     options = "ro";
    #     description = "key";
    #     wantedBy = [
    #       "initrd.target"
    #       "initrd-root-fs.target"
    #     ];
    #   }
    # ];
    boot.initrd.systemd.services.unlock-bcachefs-custom = {
      description = "Custom single bcachefs unlock for all subvolumes";

      # Make this part of the root-fs chain, not just initrd.target
      wantedBy = [
        # "initrd.target"
        "sysroot.mount"
        "initrd-root-fs.target"
      ];
      before = [
        "sysroot.mount"
        "initrd-root-fs.target"
      ];

      after = [
        # "usb_key.mount"
        "initrd-root-device.target"
      ];
      requires = [
        "initrd-root-device.target"
        primaryDeviceUnit
      ];

      # unitConfig = {
      #   # Ensure this service doesn't time out if USB detection takes a while
      #   DefaultDependencies = "no";
      # };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        KeyringMode = "shared"; # TODO so it shares with reset root below, not needed otherwise
      };

      # script = ''
      #   echo "Using USB key for bcachefs unlock: ${USB_KEY}"
      #
      #   # only try mount if the node exists
      #   if [ ! -e "${USB_KEY}" ]; then
      #     echo "USB key device ${USB_KEY} not present in initrd"
      #     exit 1
      #   fi
      #
      #   ${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /usb_key/key "${PRIMARY}"
      #   echo "bcachefs unlock successful for ${PRIMARY}"
      # '';

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

    # TODO rotate root
  }
  # Reset root for erase your darlings/impermanence/preservation
  (lib.mkIf false {
    boot.initrd.systemd.services.bcachefs-reset-root = {
      description = "Reset bcachefs root subvolume before pivot";

      # We want this to run after we've ATTEMPTED to unlock,
      # but strictly BEFORE the real root is mounted at /sysroot
      after = [
        "initrd-root-device.target"
        "cryptsetup.target"
        "unlock-bcachefs-custom.service"
      ];

      # This is the most important part: prevent sysroot from mounting until we are done resetting it
      before = [
        "sysroot.mount"
      ];

      requires = [
        primaryDeviceUnit
        "unlock-bcachefs-custom.service"
      ];
      wantedBy = [

        "initrd-root-fs.target"
        "sysroot.mount"
        "initrd.target"
      ];

      serviceConfig = {
        Type = "oneshot";
        KeyringMode = "shared";
        # Environment = "PATH=${
        #   lib.makeBinPath [
        #     # pkgs.coreutils
        #   ]
        # }:/bin:/sbin";
      };

      script = ''
        # 1. Enable Debugging
        set -x

        # 2. Define Cleanup Trap (Robust)
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

        # If unlocked, mounts instantly. If locked, prompts for password on TTY.
        echo "Mounting ${PRIMARY}..."
        if ! mount "${PRIMARY}" /primary_tmp; then
            echo "Mount failed. Cannot reset root."
            exit 1
        fi

        if [[ -e /primary_tmp/@root ]]; then
            mkdir -p /primary_tmp/@snapshots/old_roots
            
            # Use safe timestamp format (dashes instead of colons)
            timestamp=$(date --date="@$(stat -c %Y /primary_tmp/@root)" "+%Y-%m-%d_%H-%M-%S")
            
            echo "Snapshotting @root to .../$timestamp"
            bcachefs subvolume snapshot /primary_tmp/@root "/primary_tmp/@snapshots/old_roots/$timestamp"
            
            echo "Deleting current @root"
            bcachefs subvolume delete /primary_tmp/@root
        fi

        # Trap handles creating new root and unmount
      '';
    };
  })
]
