{ lib, config, ... }:
let
  cfg = config.custom_disko;
in
{
  options.custom_disko = {
    withSwap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to create a swap file.";
    };
  };
  config = {
    disko.devices = {
      disk = {
        main = {
          device = "/dev/vda";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                priority = 1;
                name = "ESP";
                start = "1M";
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  extraArgs = [
                    "-n"
                    "NIXBOOT"
                  ];
                  mountOptions = [ "umask=0077" ];
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "btrfs";
                  extraArgs = [
                    "-f"
                    "--label NIXROOT"
                  ];
                  subvolumes =
                    let
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    in
                    {
                      "@root" = {
                        inherit mountOptions;
                        mountpoint = "/";
                      };
                      "@nix" = {
                        inherit mountOptions;
                        mountpoint = "/nix";
                      };
                      "@persist" = {
                        inherit mountOptions;
                        mountpoint = "/persist";
                      };
                      "@snapshots" = {
                        inherit mountOptions;
                        mountpoint = "/.snapshots";
                      };
                      "@swap" = lib.mkIf cfg.withSwap {
                        inherit mountOptions;
                        mountpoint = "/.swapfile";
                        swap.swapfile.size = "8G";
                      };
                    };
                };
              };
            };
            postCreateHook = ''
              MNTPOINT=$(mktemp -d)
              mount -t btrfs "${config.disko.devices.disk.main.content.partitions.root.device}" "$MNTPOINT"
              trap 'umount $MNTPOINT; rmdir $MNTPOINT' EXIT
              # Ensure the snapshots directory exists
              mkdir -p $MNTPOINT/@snapshots
              # Place readonly empty root snapshot inside snapshots subvol
              btrfs subvolume snapshot -r $MNTPOINT/@root $MNTPOINT/@snapshots/_root-empty
            '';
          };
        };
      };
    };
    fileSystems."/persist".neededForBoot = true;
  };
}
