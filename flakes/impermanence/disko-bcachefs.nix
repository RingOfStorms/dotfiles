# Disko configuration for bcachefs + impermanence layout.
#
# Creates:
#   Partition 1: EFI System Partition (FAT32, 1GB)
#   Partition 2: Swap (configurable size, or omitted)
#   Partition 3: bcachefs (rest of disk, optionally encrypted)
#     Subvolumes: @root, @nix, @snapshots, @persist
#
# Usage (from NixOS live ISO):
#   sudo nix --experimental-features "nix-command flakes" run \
#     github:nix-community/disko/latest -- \
#     --mode destroy,format,mount /path/to/disko-bcachefs.nix \
#     --arg disk '"/dev/nvme0n1"' \
#     --arg swapSize '"16G"' \
#     --arg encrypted true
#
# For encrypted setups, write your passphrase to /tmp/bcachefs.key first:
#   echo -n 'your-passphrase' > /tmp/bcachefs.key
{
  disk ? "/dev/sda",
  swapSize ? "8G",
  encrypted ? false,
  ...
}:
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "fmask=0077"
                  "dmask=0077"
                ];
              };
            };
            swap = {
              priority = 2;
              size = swapSize;
              content = {
                type = "swap";
                discardPolicy = "both";
              };
            };
            primary = {
              priority = 3;
              size = "100%";
              content = {
                type = "bcachefs";
                filesystem = "main";
                label = "ssd.primary";
                extraFormatArgs = [ "--discard" ];
              };
            };
          };
        };
      };
    };

    bcachefs_filesystems = {
      main = {
        type = "bcachefs_filesystem";
        passwordFile = if encrypted then "/tmp/bcachefs.key" else null;
        subvolumes = {
          "@root" = {
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
          "@nix" = {
            mountpoint = "/nix";
            mountOptions = [ "noatime" ];
          };
          "@persist" = {
            mountpoint = "/persist";
            mountOptions = [ "noatime" ];
          };
          "@snapshots" = {
            mountpoint = "/.snapshots";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
