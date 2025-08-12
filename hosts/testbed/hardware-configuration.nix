{
  lib,
  ...
}:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  boot.initrd.postMountCommands = lib.mkAfter ''
    # Mount Btrfs volume (the device containing your root subvolumes)
    mkdir -p /btrfs_tmp
    mount -o subvol=/ /dev/disk/by-label/NIXROOT /btrfs_tmp

    # Delete current @root, then restore from snapshot
    btrfs subvolume delete /btrfs_tmp/@root || true
    btrfs subvolume snapshot /btrfs_tmp/@snapshots/root-empty /btrfs_tmp/@root

    umount /btrfs_tmp
  '';
}
