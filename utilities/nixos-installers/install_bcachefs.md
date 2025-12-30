# Install nix minimal with bcachefs filesystem

- optional encryption
- optional auto unlock with USB key
- custom iso installer
  - `nix build .\#packages.x86_64-linux.iso-minimal-stable`

## Format main drive with boot, bcachefs, & swap

### Partition with GPT table

```sh
DEVICE=sda
parted /dev/$DEVICE -- mklabel gpt
parted /dev/$DEVICE -- mkpart ESP fat32 1MB 2GB
parted /dev/$DEVICE -- set 1 esp on
# with swap
parted /dev/$DEVICE -- mkpart PRIMARY 2GB -8GB
parted /dev/$DEVICE -- mkpart SWAP linux-swap -8GB 100%
# OR no swap
parted /dev/$DEVICE -- mkpart PRIMARY 2GB 100%
```

### Format partitions

```sh
BOOT=sda1
PRIMARY=sda2
SWAP=sda3

mkfs.fat -F 32 -n BOOT /dev/$BOOT

bcachefs format --label=nixos --encrypted /dev/$PRIMARY
bcachefs unlock /dev/$PRIMARY

mkswap /dev/$SWAP
swapon /dev/$SWAP
```

> TIP: Save encryption password in password manager +
> Copy the External/Internal/Magic number output UUIDS

### Setup subvolumes

```sh
keyctl link @u @s
U=$(lsblk -o name,uuid | grep $PRIMARY | awk '{print $2}')
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
echo $DEV_B && echo $DEV_P
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
- Decide on SWAP, USB key unlock, impermanence
  - Use i001 as an example install with this setup
- Run nixos-install

```sh
# If setup remotely we can install from pushed up flake like so from the target host
HOST=i001
nixos-install --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/$HOST#$HOST"

# NOTE not sure if this works very well, seems to be partially
# or push from more powerful machine that can build faster, on host
HOST=juni
cd hosts/$HOST && nixos-rebuild build --flake ".#$HOST"
NIX_SSHOPTS="-i /run/agenix/nix2nix" nix-copy-closure --to $HOST --use-substitutes --gzip result
CLOSURE=$(readlink -f result)
echo $CLOSURE
# on target
nixos-install --system $CLOSURE
```

- After boot

```sh
nh os switch "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/i001#nixosConfigurations.i001"
# OR
cd ~/.config
git clone https://git.joshuabell.xyz/ringofstorms/dotfiles nixos-config
cd ~/.config/nixos-config/hosts/i001
```

or from host machine? TODO haven't tried this fully

```sh
NIX_SSHOPTS="-i /run/agenix/nix2nix" sudo nixos-rebuild switch --flake "~/.config/nixos-config/hosts/i001#nixosConfigurations.i001" --target-host luser@10.12.14.119 --build-host localhost
NIX_SSHOPTS="-i /run/agenix/nix2nix" sudo nixos-rebuild switch --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/i001#i001" --target-host luser@10.12.14.119 --build-host localhost
nh os switch -H i001 --target-host luser@10.12.14.119 --build-host localhost -n ".config/nixos-config/hosts/i001"
```

## USB Key

```sh
DEVICE=sdb
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
