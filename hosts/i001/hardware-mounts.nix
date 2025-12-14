{ lib, pkgs, ... }:
let
  BOOT = "/dev/disk/by-uuid/ABDB-2A38";
  PRIMARY_UUID = "08610781-26d3-456f-9026-35dd4a40846f";
  PRIMARY = "/dev/disk/by-uuid/${PRIMARY_UUID}";

  USB_KEY = "/dev/disk/by-uuid/9985-EBD1";

  inherit (lib)
    hasPrefix
    removePrefix
    removeSuffix
    replaceStrings
    stringToCharacters
    ;
  inherit (lib.strings) normalizePath escapeC;
  # FROM  https://github.com/NixOS/nixpkgs/blob/5384341652dc01f8b01a3d227ae29e2dfbe630ba/nixos/lib/utils.nix#L101C1-L120C9
  escapeSystemdPath =
    s:
    let
      replacePrefix =
        p: r: s:
        (if (hasPrefix p s) then r + (removePrefix p s) else s);
      trim = s: removeSuffix "/" (removePrefix "/" s);
      normalizedPath = normalizePath s;
    in
    replaceStrings [ "/" ] [ "-" ] (
      replacePrefix "." (escapeC [ "." ] ".") (
        escapeC (stringToCharacters " !\"#$%&'()*+,;<=>=@[\\]^`{|}~-") (
          if normalizedPath == "/" then normalizedPath else trim normalizedPath
        )
      )
    );
in
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
  fileSystems."/.swap" = {
    device = PRIMARY;
    fsType = "bcachefs";
    options = [
      "X-mount.mkdir"
      "X-mount.subdir=@swap"
      "noatime"
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

  # SWAP
  swapDevices = [
    # {
    #   device = "/.swap/swapfile";
    #   size = 8 * 1024; # Creates an 8GB swap file
    # }
  ];

  # PRIMARY unencrypt
  boot.initrd.systemd.enable = true;
  boot.supportedFilesystems = [
    "bcachefs"
    "vfat"
  ];

  # 1. Disable the automatically generated unlock services
  boot.initrd.systemd.services = {
    # the module creates services named unlock-bcachefs-<escaped-mountpoint>
    "unlock-bcachefs-${escapeSystemdPath "/"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/.old_roots"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/nix"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/.snapshots"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/.swap"}".enable = false;
    "unlock-bcachefs-${escapeSystemdPath "/persist"}".enable = false;

    # 2. Your single custom unlock unit
    unlock-bcachefs-custom = {
      description = "Custom single bcachefs unlock for all subvolumes";

      wantedBy = [ "initrd.target" ];
      before = [ "sysroot.mount" ];

      # Wait for udev so the /dev/disk/by-uuid path and the USB key appear
      requires = [ "systemd-udev-settle.service" ];
      after = [ "systemd-udev-settle.service" ];

      serviceConfig = {
        Type = "oneshot";
        # NOTE: put the real password here, or better: read it from USB_KEY
        # ExecStart = ''
        #   /bin/sh -c 'echo "password" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock ${PRIMARY}'
        # '';
        # ExecStart = ''
        #   /bin/sh -c 'mount -o ro ${USB_KEY} /key && \
        #     cat /key/bcachefs.key | ${pkgs.bcachefs-tools}/bin/bcachefs unlock ${PRIMARY}'
        # '';

        # We inline a script that roughly mimics tryUnlock + openCommand behavior,
        # but uses a key file from the USB stick instead of systemd-ask-password.
        ExecStart = ''
          /bin/sh -eu

          DEVICE="${PRIMARY_UUID}"
          UUID="${PRIMARY_UUID}" 

          echo "waiting for device to appear ''${DEVICE}"
          success=false
          target=""

          # approximate tryUnlock loop from the module
          for try in $(seq 10); do
            if [ -e "''${DEVICE}" ]; then
              target="$(readlink -f "''${DEVICE}")"
              success=true
              break
            else
              # try to resolve by uuid via blkid
              if target="$(blkid --uuid "''${UUID}" 2>/dev/null)"; then
                success=true
                break
              fi
            fi
            echo -n "."
            sleep 1
          done
          echo

          if [ "''${success}" != true ]; then
            echo "Cannot find device ''${DEVICE} (UUID=''${UUID})" >&2
            exit 1
          fi

          DEVICE="''${target}"

          # pre-check: is it encrypted / already unlocked?
          if ! ${pkgs.bcachefs-tools}/bin/bcachefs unlock -c "''${DEVICE}" > /dev/null 2>&1; then
            echo "Device ''${DEVICE} is not encrypted or cannot be probed with -c" >&2
            exit 1
          fi

          # mount USB, read key, unlock – adjust paths as you like
          # mkdir -p /key
          # mount -o ro "${USB_KEY}" /key
          #
          # if [ ! -f /key/bcachefs.key ]; then
          #   echo "Missing /key/bcachefs.key on USB; cannot unlock" >&2
          #   umount /key || true
          #   exit 1
          # fi

          # cat /key/bcachefs.key | ${pkgs.bcachefs-tools}/bin/bcachefs unlock "''${DEVICE}"
          echo "test" | ${pkgs.bcachefs-tools}/bin/bcachefs unlock "''${DEVICE}"

          # umount /key || true

          echo "bcachefs unlock successful for ''${DEVICE}"
        '';
      };
    };
  };

  # TODO this works for resetting root!
  # boot.initrd.postResumeCommands = lib.mkAfter ''
  #   echo "test" | bcachefs unlock ${PRIMARY}
  #
  #   mkdir /primary_tmp
  #   mount ${PRIMARY} primary_tmp/
  #   if [[ -e /primary_tmp/@root ]]; then
  #       mkdir -p /primary_tmp/@old_roots
  #       bcachefs set-file-option /primary_tmp/@old_roots --compression=zstd
  #
  #       timestamp=$(date --date="@$(stat -c %Y /primary_tmp/@root)" "+%Y-%m-%-d_%H:%M:%S")
  #       bcachefs subvolume snapshot /primary_tmp/@root "/primary_tmp/@old_roots/$timestamp"
  #       bcachefs subvolume delete /primary_tmp/@root
  #   fi
  #
  #   for i in $(find /primary_tmp/old_roots/ -maxdepth 1 -mtime +30); do
  #       bcachefs subvolume delete "$i"
  #   done
  #
  #   bcachefs subvolume create /primary_tmp/@root
  #   umount /primary_tmp
  # '';
}
