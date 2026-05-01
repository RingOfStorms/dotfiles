# Setup installer USB

```sh
# get latest nixpkgs for iso
cd utilities/nixos-installers && flake update -a && cd ../..
nix build "./utilities/nixos-installers/flake.nix#packages.x86_64-linux.iso-minimal-stable"
# Flash to usb
DEVICE=/dev/sdX
ISO=result/iso/nixos.*iso
sudo dd if="$ISO" of="$DEVICE" bs=4M status=progress oflag=sync
```

# Install nix minimal with bcachefs filesystem

- optional encryption
- optional auto unlock with USB key

## Format main drive with boot, bcachefs, & swap

### Partition with GPT table

```sh
DEVICE=sda
parted /dev/$DEVICE -- mklabel gpt
parted /dev/$DEVICE -- mkpart ESP fat32 1MB 5GB
parted /dev/$DEVICE -- set 1 esp on
# with swap
parted /dev/$DEVICE -- mkpart PRIMARY 5GB -##GB
parted /dev/$DEVICE -- mkpart SWAP linux-swap -##GB 100%
# OR no swap
parted /dev/$DEVICE -- mkpart PRIMARY 5GB 100%
```

### Format partitions

```sh
BOOT=$DEVICE"p1"
PRIMARY=$DEVICE"p2"
SWAP=$DEVICE"p3"
echo $BOOT $PRIMARY $SWAP

mkfs.fat -F 32 -n BOOT /dev/$BOOT

bcachefs format --label=nixos --encrypted /dev/$PRIMARY | tee primary.log
bcachefs unlock /dev/$PRIMARY

mkswap /dev/$SWAP
swapon /dev/$SWAP
```

> TIP: Save encryption password in password manager +

### Setup subvolumes

```sh
keyctl link @u @s
# Gets the external UUID of primary bcachefs
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
- Run nixos-install (with one of the commands below)

```sh
# If setup remotely we can install from pushed up flake like so from the target host
HOST=i001
nixos-install --flake "git+https://git.joshuabell.xyz/ringofstorms/dotfiles?dir=hosts/$HOST#$HOST" --option tarball-ttl 0
# or push from more powerful machine that can build faster, on host
HOST=oren
HOST_IP=10.12.14.124
cd hosts/$HOST
nixos-rebuild build --flake ".#$HOST"
NIX_SSHOPTS="-i /var/lib/openbao-secrets/nix2nix_2026-03-15" nix-copy-closure --to root@$HOST_IP --use-substitutes --gzip result
CLOSURE=$(readlink -f result) && echo $CLOSURE
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
# OR via flashdrive
HOST=juni
cd ~/.config/nixos-config/hosts/$HOST
nixos-rebuild build --flake ".#$HOST"
CLOSURE="$(readlink -f result)"
nix-store --export $(nix-store -qR "$CLOSURE") > /run/media/josh/69F7-F789/system.export
# on target host
nix-store --import < /path/to/system.export
# ls -td /nix/store/*-nixos-system-*
CLOSURE=""
nix-env -p /nix/var/nix/profiles/system --set "$CLOSURE"
"$CLOSURE"/bin/switch-to-configuration switch
```

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

## Post Install First boot setup

### Set user password from default

`passwd` `password1` -> new pass

### Create the machine identity in Zitadel

In `https://sso.joshuabell.xyz` (admin):

1. **Users → Machine Users → + New**
   - Name: the host name (e.g. `oren`)
   - **Access Token Type: JWT**
   - Save
2. **Projects → <the OpenBao-trusted project> → Authorizations**
   - Grant the new machine user the role(s) matching its trust tier
     (e.g. `machines-hightrust` for oren/juni, `machines-lowtrust`
     for gp3/joe).
3. Back on the machine user page: **Keys → + New**, type **JSON**,
   download the file. This is `machine-key.json`.

### 2. Copy the key to the host

`/machine-key.json` is in the impermanence essentials persist set
(see `flakes/impermanence/shared_persistence/essentials.nix`), so the
real file lives at `/persist/machine-key.json` and is bind-mounted to
`/machine-key.json` at boot.

```sh
HOST_IP=10.12.14.124
 scp -i /var/lib/openbao-secrets/nix2nix_2026-03-15 ~/Downloads/370960357004410883.json josh@$HOST_IP:/tmp/machine-key.json
sudo install -m 0400 -o root -g root /tmp/machine-key.json /persist/machine-key.json &&
sudo ln -sf /persist/machine-key.json /machine-key.json &&
rm /tmp/machine-key.json
```

### 3. Kick the secret-fetch pipeline

The `zitadel-mint-jwt` timer fires roughly every 30s, but you can
force it immediately:

```sh
sudo systemctl start zitadel-mint-jwt.service &&
sudo systemctl start vault-agent.service &&
sudo systemctl start openbao-secrets-ready.service &&
sudo ls -la /var/lib/openbao-secrets/
```

### 4. Tailscale / Headscale auto-join

```sh
sudo systemctl restart tailscaled-autoconnect.service
tailscale status
```

```sh
sudo systemctl restart atuin-autologin.service
atuin sync -f
```
