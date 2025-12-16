{
  config,
  utils,
  pkgs,
  lib,
  ...
}:
let
  USB_KEY = "/dev/disk/by-uuid/63a7bd87-d644-43ea-83ba-547c03012fb6";

  BOOT = "/dev/disk/by-uuid/ABDB-2A38";
  PRIMARY_UUID = "08610781-26d3-456f-9026-35dd4a40846f";
  PRIMARY = "/dev/disk/by-uuid/${PRIMARY_UUID}";

  inherit (utils) escapeSystemdPath;

  primaryDeviceUnit = "${escapeSystemdPath PRIMARY}.device";
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
      ];
    };
    fileSystems."/.old_roots" = {
      device = PRIMARY;
      fsType = "bcachefs";
      options = [
        "nofail" # this may not exist yet just skip it
        "X-mount.mkdir"
        "X-mount.subdir=@old_roots"
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
        "X-mount.subdir=@root"
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
  # SWAP
  {
    swapDevices = [
      # {
      #   device = "/.swap/swapfile";
      #   size = 8 * 1024; # Creates an 8GB swap file
      # }
    ];
  }
  # Disable bcachefs built in password prompts for all mounts (which asks for every single subdir mount above
  {
    boot.initrd.systemd.enable = true;

    # https://github.com/NixOS/nixpkgs/blob/6cdf2f456a57164282ede1c97fc5532d9dba1ee0/nixos/modules/tasks/filesystems/bcachefs.nix#L254-L259
    systemd.services =
      # let
      #   isSystemdNonBootBcache = v: (v.fsType == "bcachefs") && (!utils.fsNeededForBoot v);
      #   bcacheNonBoots = lib.filterAttrs (k: v: isSystemdNonBootBcache v) config.fileSystems;
      # in
      # (lib.mapAttrs (k: v: { enable = false; }) bcacheNonBoots);
      {
        # NOTE that neededForBoot fs's dont end up in this list
        "unlock-bcachefs-${escapeSystemdPath "/.old_roots"}".enable = false;
        "unlock-bcachefs-${escapeSystemdPath "/.snapshots"}".enable = false;
        "unlock-bcachefs-${escapeSystemdPath "/.swap"}".enable = false;
        "unlock-bcachefs-${escapeSystemdPath "/persist"}".enable = false;
      };

    # https://github.com/NixOS/nixpkgs/blob/6cdf2f456a57164282ede1c97fc5532d9dba1ee0/nixos/modules/tasks/filesystems/bcachefs.nix#L291
    boot.initrd.systemd.services =
      # let
      #   isSystemdBootBcache = v: (v.fsType == "bcachefs") && (utils.fsNeededForBoot v);
      #   bcacheBoots = lib.filterAttrs (k: v: isSystemdBootBcache v) config.fileSystems;
      # in
      # (lib.mapAttrs (k: v: { enable = false; }) bcacheBoots);
      {
        "unlock-bcachefs-${escapeSystemdPath "/sysroot"}".enable = false;
        "unlock-bcachefs-${escapeSystemdPath "/"}".enable = false;
        "unlock-bcachefs-${escapeSystemdPath "/nix"}".enable = false;
      };
  }
  # Bcachefs auto decryption
  {
    boot.supportedFilesystems = [
      "bcachefs"
    ];

    # boot.initrd.systemd.mounts = [
    #   {
    #     what = USB_KEY;
    #     type = "bcachefs";
    #     where = "/usb_key";
    #     options = "ro";
    #     description = "key";
    #     wantedBy = [
    #       "initrd.target"
    #     ];
    #   }
    # ];
    boot.initrd.systemd.services.unlock-bcachefs-custom = {
      description = "Custom single bcachefs unlock for all subvolumes";

      wantedBy = [ "initrd.target" ];
      before = [ "sysroot.mount" ];

      requires = [ primaryDeviceUnit ];
      after = [ primaryDeviceUnit ];
      script = ''
        echo "Using test password..."
        echo "test" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock "${PRIMARY}"
        echo "bcachefs unlock successful for ${PRIMARY}"
      '';
      # script = ''
      #   echo "Using USB key for bcachefs unlock: ${USB_KEY}"
      #
      #   echo "test" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock "${PRIMARY}"
      #   echo "done...."
      #   exit 0
      #
      #   # only try mount if the node exists
      #   if [ ! -e "${USB_KEY}" ]; then
      #     echo "USB key device ${USB_KEY} not present in initrd"
      #     exit 1
      #   fi
      #   ${pkgs.bcachefs-tools}/bin/bcachefs unlock -f /usb_key/key "${PRIMARY}"
      #   echo "bcachefs unlock successful for ${PRIMARY}"
      # '';
    };

    # TODO rotate root
  }
  # Reset root for erase your darlings/impermanence/preservation
  {
    # boot.initrd.systemd.services.bcachefs-reset-root = {
    #   description = "Reset bcachefs root subvolume before pivot";
    #   wantedBy = [ "initrd.target" ];
    #
    #   after = [
    #     "initrd-root-device.target"
    #     "cryptsetup.target"
    #     "unlock-bcachefs-custom"
    #   ];
    #   requires = [ primaryDeviceUnit ];
    #
    #   serviceConfig = {
    #     Type = "oneshot";
    #     # initrd has a minimal PATH; set one explicitly
    #     Environment = "PATH=/bin:/sbin:/usr/bin:/usr/sbin";
    #     # If tools are in /usr, this helps ensure it's in the initrd
    #     # (you may also need environment.systemPackages + boot.initrd.includeDefaultModules)
    #     ExecStart = pkgs.writeShellScript "bcachefs-reset-root" ''
    #       set -euo pipefail
    #
    #       PRIMARY=${PRIMARY}
    #
    #       echo "Unlocking bcachefs volume ${PRIMARY}..."
    #       echo "test" | bcachefs unlock "''${PRIMARY}"
    #
    #       mkdir -p /primary_tmp
    #       mount "''${PRIMARY}" /primary_tmp
    #
    #       if [[ -e /primary_tmp/@root ]]; then
    #         mkdir -p /primary_tmp/@old_roots
    #         bcachefs set-file-option /primary_tmp/@old_roots --compression=zstd
    #
    #         timestamp=$(date --date="@$(stat -c %Y /primary_tmp/@root)" "+%Y-%m-%-d_%H:%M:%S")
    #         bcachefs subvolume snapshot /primary_tmp/@root "/primary_tmp/@old_roots/$timestamp"
    #         bcachefs subvolume delete /primary_tmp/@root
    #
    #         # Cleanup old snapshots (>30 days)
    #         # Note: path was /primary_tmp/old_roots in your snippet; using @old_roots for consistency
    #         for i in $(find /primary_tmp/@old_roots/ -maxdepth 1 -mtime +30); do
    #           bcachefs subvolume delete "$i"
    #         done
    #       fi
    #
    #       bcachefs subvolume create /primary_tmp/@root
    #       umount /primary_tmp
    #     '';
    #   };
    # };
  }
]
