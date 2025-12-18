## Install nix minimal with btrfs filesystem + luks encryption

```bash
# Partition main drive with btrfs
# tip: lsblk
# use correct drive name
export D=sda

# Partitioning
# make GPT partition table
parted /dev/$D -- mklabel gpt
# make root partition (2GB offset for boot)
parted /dev/$D -- mkpart NIXROOT 2GB 100%
# make boot partition, 1MB alignment offset
parted /dev/$D -- mkpart ESP fat32 1MB 2GB 
# make boot partition bootable
parted /dev/$D -- set 2 esp on 

# NOTE this is not bulletproof, check actual name and set these appropriately
export ROOT=$D"1"
export BOOT=$D"2"

# Anything else to partition before moving on?

# Encryption Luks (optional)
export ENC=true
cryptsetup luksFormat /dev/$ROOT
cryptsetup luksOpen /dev/$ROOT cryptroot

if [ $ENC = true ]; then 
    ROOTP="/dev/mapper/cryptroot"
else
    ROOTP="/dev/$ROOT"
fi

# Formatting
mkfs.fat -F 32 -n NIXBOOT /dev/$BOOT
mkfs.btrfs -fL NIXROOT $ROOTP

# Subvolumes (so snapshots 
mount -o subvolid=5 "$ROOTP" /mnt
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@nix
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@persist
umount /mnt

# Mount for real system use
mount -o subvol=@root,compress=zstd "$ROOTP" /mnt
mkdir -p /mnt/{nix,boot,.snapshots,.swap,persist}

mount -o umask=077 /dev/disk/by-label/NIXBOOT /mnt/boot

mount -o subvol=@nix,compress=zstd,noatime "$ROOTP" /mnt/nix
mount -o subvol=@swap,noatime "$ROOTP" /mnt/.swap
mount -o subvol=@snapshots,compress=zstd,noatime "$ROOTP" /mnt/.snapshots
mount -o subvol=@persist,compress=zstd,noatime "$ROOTP" /mnt/persist

# Create config
nixos-generate-config --root /mnt
```

### Fix hardware-configuration

```hardware-configuration.nix
# @root options + "compress=zstd"
# @nix options + "compress=zstd" "noatime"
# @swap options + "noatime"
# @snapshots options + "compress=zstd" "noatime"
# @persist options + "compress=zstd"
#   + neededForBoot = true;

# add Swap device
swapDevices = [{ 
  device = "/.swap/swapfile"; 
  size = 8*1024; # Creates an 8GB swap file 
}];

# https://wiki.nixos.org/wiki/Btrfs#Scrubbing
services.btrfs.autoScrub = {
  enable = true;
  # syntax defined by https://www.freedesktop.org/software/systemd/man/systemd.time.html#Calendar%20Events
  interval = "monthly";
  fileSystems = [ "/" ];
};
```

### Add initial system config changes

```sh
curl -o /mnt/etc/nixos/flake.nix https://git.joshuabell.xyz/ringofstorms/dotfiles/raw/branch/master/utilities/nixos-installers/new-flake.nix
```

Open and edit config name/location as desired.

### Auto unlock luks (optional) - USB key

```sh
# Format if needed (fat32 for compatibility)
sudo parted /dev/DRIVEDEVICE
  mklabel gpt
  mkpart primary 1MiB 9MiB
  quit

# Create key
dd if=/dev/random of=/key_tmpfs/keyfile bs=1024 count=4
# writing some random data, choose a random offset
sudo dd if=/dev/urandom of=/dev/sdX1 bs=4096 count=4 seek=5443 status=none
sudo cryptsetup luksAddKey /dev/LUKSROOT --new-keyfile /dev/USBKEY --new-keyfile-size 5000 --new-keyfile-offset 5443
```

In hardware-configuration ensure these are all added:

```hardware-configuration.nix
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ehci_pci" "usb_storage" "uas"
  ];

  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/LUKS_UUID (same as root above)";

    # Auto decrypt
    keyFileTimeout = 2;
    keyFile = "/dev/disk/by-uuid/KEY UUID";
    # Set if used in generation command above
    keyFileSize = 5000;
    keyFileOffset = 5443;

    tryEmptyPassphrase = true;
    fallbackToPassword = true;
    crypttabExtraOpts = [ "tries=2" ];
  };
```

### Impermanence BTRFS setup (optional)

```hardware-configuration.nix
boot.initrd.postResumeCommands = lib.mkAfter ''
    mkdir /btrfs_tmp
    mount /dev/ROOT_FILESYSTEM /btrfs_tmp
    if [[ -e /btrfs_tmp/@root ]]; then
        mkdir -p /btrfs_tmp/old_roots
        timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/root)" "+%Y-%m-%-d_%H:%M:%S")
        mv /btrfs_tmp/root "/btrfs_tmp/old_roots/$timestamp"
    fi

    delete_subvolume_recursively() {
        IFS=$'\n'
        for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
            delete_subvolume_recursively "/btrfs_tmp/$i"
        done
        btrfs subvolume delete "$1"
    }

    for i in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mtime +30); do
        delete_subvolume_recursively "$i"
    done

    btrfs subvolume create /btrfs_tmp/@root
    umount /btrfs_tmp
'';

```

### Install nixos

`sudo nixos-install`
`reboot` and remove start up media



## Impermanence Tips

```sh
sudo mkdir /btrfs_root
sudo mount -o subvolid=5,compress=zstd /dev/mapper/cryptroot /btrfs_root
```












TODO

> Easiest to ssh into the machine for these steps so you can copy paste...

- `cat /etc/ssh/ssh_host_ed25519_key.pub ~/.ssh/id_ed25519.pub`
  - On an already onboarded computer copy these and add them to secrets/secrets.nix file
    - `nix run github:yaxitech/ragenix -- --rules ~/.config/nixos-config/common/secrets/secrets/secrets.nix -r`
  - Maybe copy hardware/configs over and setup, otherwise do it on the client machine
- git clone nixos-config `git clone https://git.joshuabell.xyz/ringofstorms/dotfiles ~/.config/nixos-config`
- Setup config as needed
  - add hosts dir and files needed
- `sudo nixos-rebuild switch --flake ~/.config/nixos-config/hosts/$HOSTNAME`
- Update remote, ssh should work now: `cd ~/.config/nixos-config && git remote remove origin && git remote add origin "ssh://git.joshuabell.xyz:3032/ringofstorms/dotfiles" && git pull origin master`

## Local tooling

- bitwarden setup/sign into self hosted vault

- atuin setup
  - if atuin is on enable that mod in configuration.nix, make sure to `atuin login` get key from existing device
  - TODO move key into secrets and mount it to atuin local share
- ssh key access, ssh iden in config in nix config

### Notes

Dual booting windows?

- If there is a new boot partition being used than the old windows one, copy over the /boot/EFI/Microsoft folder into the new boot partition, same place
- If the above auto probing for windows does not work, you can also manually add in a windows.conf in the loader entries: /boot/loader/entries/windows.conf:

```
title Windows 11
efi   /EFI/Microsoft/Boot/bootmgfw.efi
```

# Settings references

- Flake docs: <https://nixos.wiki/wiki/Flakes>
- nixos: <https://search.nixos.org/options>
- home manager: <https://nix-community.github.io/home-manager/options.xhtml>
  TODO make an offline version of this, does someone else have this already?

# TODO

# Nix Infrastructure & Automation Improvements

- [ ] **Document or automate new host bootstrap:**  
  - Script or steps: boot custom ISO, git clone config, secrets onboarding (agenix), nixos-install with flake config.
  - Provide an example shell script or README note for a single-command initial setup.
- [ ] **(Optional) Add an ephemeral “vm-experiment” target for NixOS VM/dev testing.**  
  - Use new host config with minimal stateful services, then  
      `nixos-rebuild build-vm --flake .#vm-experiment`
- [ ] **Remote build reliability:**  
  - Parametrize/automate remote builder enable/disable.
  - Add quickstart SSH builder key setup instructions per-host in README.
- [ ] **Add [disko](https://github.com/nix-community/disko) to declaratively manage disk/partition creation for new installs and reinstalls.**

- work on secrets pre ragenix, stormd pre install for all the above bootstrapping steps would be ideal
- reduce home manager, make per user modules support instead
- Ensure my neovim undohistory/auto saves don't save `.age` files as they can be sensitive.

# Server hosts

simply run `deploy` in the host root and it will push changes to the server (or `deploy_[oracle|linode] <name>` from root)
