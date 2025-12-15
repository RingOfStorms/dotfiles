# Install nix minimal with bcachefs filesystem

- optional encryption
- optional auto unlock with USB key
- custom iso installer
  - `nix build .\#packages.x86_64-linux.iso-minimal-stable`

## Format main drive with boot partition

### Partition with GPT

```sh
DEVICE=sda
parted /dev/$DEVICE -- mklabel gpt
parted /dev/$DEVICE -- mkpart ESP fat32 1MB 2GB
parted /dev/$DEVICE -- set 1 esp on

parted /dev/$DEVICE -- mkpart PRIMARY 2GB -8GB
parted /dev/$DEVICE -- mkpart SWAP linux-swap -8GB 100%

parted /dev/$DEVICE -- mkpart PRIMARY 2GB 100%
```

### Format partitions

- boot

```sh
BOOT=sda1
mkfs.fat -F 32 -n BOOT /dev/$BOOT
```

- primary

```sh
PRIMARY=sda2
# keyctl link @u @s
bcachefs format --label=nixos --encrypted /dev/$PRIMARY
bcachefs unlock /dev/$PRIMARY
```

- swap (optional)

```sh
SWAP=sda3
mkswap /dev/$SWAP
swapon /dev/$SWAP
```

### Setup subvolumes

```sh
# keyctl link @u @s
U=$(lsblk -o fsType,uuid | grep bcachefs | awk '{print $2}')
echo $U
mount /dev/disk/by-uuid/$U /mnt

bcachefs subvolume create /mnt/@root
bcachefs subvolume create /mnt/@nix
bcachefs set-file-option /mnt/@nix --compression=zstd
bcachefs subvolume create /mnt/@snapshots
bcachefs set-file-option /mnt/@snapshots --compression=zstd
bcachefs subvolume create /mnt/@persist

umount /mnt
```

> Tip `getfattr -d -m '^bcachefs\.' filename`

> Note: Format any additional drives if you need to

### Mount subvolumes

```sh
DEV_B="/dev/disk/by-uuid/"$(lsblk -o name,uuid | grep $BOOT | awk '{print $2}')
DEV_P="/dev/disk/by-uuid/"$(lsblk -o name,uuid | grep $PRIMARY | awk '{print $2}')
mount -t bcachefs -o X-mount.subdir=@root $DEV_P /mnt
mount -t vfat $DEV_B /mnt/boot --mkdir
mount -t bcachefs -o X-mount.mkdir,X-mount.subdir=@nix,relatime $DEV_P /mnt/nix
mount -t bcachefs -o X-mount.mkdir,X-mount.subdir=@snapshots,relatime $DEV_P /mnt/.snapshots
mount -t bcachefs -o X-mount.mkdir,X-mount.subdir=@persist $DEV_P /mnt/persist
```

### Generate hardware config

```sh
nixos-generate-config --root /mnt
```

- Copy useful bits out into real config in repo (primarily swap/kernel modules)
- Run nixos-install

```sh
nixos-install --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/i001#i001"
# nh os switch "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/i001#i001"
```

or from host machine? TODO haven't tried this fully

```sh
NIX_SSHOPTS="-i /run/agenix/nix2nix" sudo nixos-rebuild switch --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/i001#i001" --target-host luser@10.12.14.157 --build-host localhost

```

## USB Key

```sh
DEVICE=sdc
parted /dev/$DEVICE -- mklabel gpt
parted /dev/$DEVICE -- mkpart KEY fat32 1MB 100%
DEVICE=$DEVICE"1"
bcachefs format /dev/$DEVICE
UUID=$(lsblk -o name,uuid | grep $DEVICE | awk '{print $2}')
echo For setting up in config: $UUID
# TODO mount and write key to /key
mount -t bcachefs --mkdir /dev/$DEVICE /usb_key
echo "test" > /usb_key/key
umount /usb_key && rmdir /usb_key
```

