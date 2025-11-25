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
umount /mnt

# Mount for real system use
mount -o subvol=@root,compress=zstd,noatime "$ROOTP" /mnt
mkdir -p /mnt/{nix,boot,.snapshots,.swap}
mount -o subvol=@nix,compress=zstd,noatime "$ROOTP" /mnt/nix
mount -o subvol=@snapshots,compress=zstd,noatime "$ROOTP" /mnt/.snapshots
mount -o subvol=@swap,noatime "$ROOTP" /mnt/.swap

# Create config
nixos-generate-config --root /mnt
```

TODO leftoff here
`!a%oz0rrtsrnhCRULxpMBqdIlh28bpom$%$1%O1Yh` luks password on test machine for now
### Fix hardware-configuration
```hardware-configuration.nix

```
prompt="Add swap file?" var=SWP && read -r -p "$prompt (y/n) [n]: " resp && resp=$(echo "$resp" | tr '[:upper:]' '[:lower:]'); [[ "$resp" == "y" || "$resp" == "yes" || "$resp" == "1" ]] && export $var=true || export $var=false
if [ $SWP = true ]; then
  SIZE=$(grep MemTotal /proc/meminfo | awk 'function ceil(x, y){y=int(x); return(x>y? y+1:y)} {print ceil($2/1024/1024)}')
  read -r -p "Custom size in GB? [$SIZE]" SIZE_OVERRIDE
  SIZE="${SIZE_OVERRIDE:-$SIZE}"

  if [ $SUBV = true ]; then
    SWAP_DEVICE='  swapDevices = [ { device = "/.swap/file"; size = '$SIZE' * 1024; } ];'
  else
    SWAP_DEVICE='  swapDevices = [ { device = "/.swapfile"; size = '$SIZE' * 1024; } ];'
  fi
  sed -i "/swapDevices/c\\$SWAP_DEVICE" /mnt/etc/nixos/hardware-configuration.nix
  echo "Added swap device to hardware configuration"
fi

echo "Getting initial config for Jason"
curl -o /mnt/etc/nixos/jason.nix https://gist.joshuabell.xyz/ringofstorms/jason-nix/raw/HEAD/jason.nix
sed -i '/\.\/hardware-configuration.nix/a \      ./jason.nix' /mnt/etc/nixos/configuration.nix
echo "Added config to imports of configuration.nix"

echo "Installing nixos"
sudo nixos-install
```

- Partitions
  - `parted /dev/DEVICE -- mklabel gpt` - make GPT partition table
  - `parted /dev/DEVICE -- mkpart NIXROOT 2GB 100%` - make root partition (2GB offset for boot)
  - `parted /dev/DEVICE -- mkpart ESP fat32 1MB 2GB` - make boot partition (2GB)
  - `parted /dev/DEVICE -- set 2 esp on` - make boot bootable
- LUKS Encryption (optional)
  - `cryptsetup luksFormat /dev/DEVICE_1`
    - Create passphrase and save to bitwarden
  - `cryptsetup luksOpen /dev/DEVUCE_1 cryptroot`
  - Create keyfile for auto-unlock (optional)
    - `dd if=/dev/random of=/tmp/keyfile_DEVICE_1 bs=1024 count=4`
    - `chmod 400 /tmp/keyfile`
    - `cryptsetup luksAddKey /dev/DEVICE_1 /tmp/keyfile_DEVICE_1`
- Formatting
- `mkfs.btrfs -L NIXROOT /dev/mapper/cryptroot`
  - `/dev/sda1` if not encyrpted instead of dev mapper cryptroot
- `mkfs.fat -F 32 -n NIXBOOT /dev/DEVICE_2`
- Create btrfs subvolumes (optional: for better snapshot perf)
  - `mount /dev/mapper/cryptroot /mnt` (`/dev/sda1` for non encrypted)
  - `btrfs subvolume create /mnt/root`
  - `btrfs subvolume create /mnt/nix`
  - `btrfs subvolume create /mnt/snapshots`
  - `umount /mnt`
- Mount (with sub vols above)
  - `mount -o subvol=root,compress=zstd,noatime /dev/mapper/cryptroot /mnt`
  - `mkdir -p /mnt/{nix,boot,.snapshots}`
  - `mount -o subvol=nix,compress=zstd,noatime /dev/mapper/cryptroot /mnt/nix`
  - `mount -o subvol=snapshots,compress=zstd,noatime /dev/mapper/cryptroot /mnt/.snapshots`
  - `mount -o umask=077 /dev/disk/by-label/NIXBOOT /mnt/boot`
- Mount (with no sub vols)
  - `mount -o compress=zstd,noatime /dev/mapper/cryptroot /mnt`
  - `mkdir -p /mnt/boot`
  - `mount -o umask=077 /dev/disk/by-label/NIXBOOT /mnt/boot`
- Add SWAP device (optional)
  - in hardware config

```nix
swapDevices = [
  {
    device = "/.swapfile";
    size = 32 * 1024; # 32GB
  }
];
```

- Copy keyfile for auto-unlock (optional)
  - `cp /tmp/keyfile_DEVICE_1 /mnt/boot/keyfile_DEVICE_1`
  - `chmod 400 /mnt/boot/keyfile_DEVICE_1`
- If Encrypted keyfile exists
  - Add to hardware config

```nix
boot.initrd.secrets = {
  "/keyfile_DEVICE_1" = "/boot/keyfile_DEVICE_1";
};

boot.initrd.luks.devices
```

2. Install and setup nixos

- nixos config and hardware config
  - `export HOSTNAME=desired_hostname_for_this_machine`
  - `export USERNAME=desired_username_for_admin_on_this_machine` (josh)
  - `nixos-generate-config --root /mnt`
  - `cd /mnt/etc/nixos`
  - `curl -O --proto '=https' --tlsv1.2 -sSf https://git.joshuabell.xyz/ringofstorms/dotfiles/raw/branch/master/onboard.sh`
  - `chmod +x onboard.sh && ./onboard.sh`
  - verify hardware config, run `nixos-install`
  - `reboot`
- log into USERNAME with `password1`, use `passwd` to change the password

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

- [ ] **Replace deployment scripts with [`deploy-rs`](https://github.com/serokell/deploy-rs)** for declarative, hands-off host updates.  
    Remove manual `deploy_linode`/`deploy_oracle` scripts. Use `deploy-rs` to apply updates across one or all hosts, including remote builds.
- [ ] **Add `isoImage` outputs for every host for instant USB/boot media creation.**  
    Use:  

    ```
    packages.x86_64-linux.install-iso = nixosConfigurations.<host>.config.system.build.isoImage;
    ```

    Then:  

    ```
    nix build .#packages.x86_64-linux.install-iso
    ```

- [ ] **Document or automate new host bootstrap:**  
  - Script or steps: boot custom ISO, git clone config, secrets onboarding (agenix), nixos-install with flake config.
  - Provide an example shell script or README note for a single-command initial setup.
- [ ] **(Optional) Add an ephemeral “vm-experiment” target for NixOS VM/dev testing.**  
  - Use new host config with minimal stateful services, then  
      `nixos-rebuild build-vm --flake .#vm-experiment`
- [ ] **Remote build reliability:**  
  - Parametrize/automate remote builder enable/disable.
  - Add quickstart SSH builder key setup instructions per-host in README.
  - (Optional) Use deploy-rs's agent forwarding and improve errors if builder can't be reached at deploy time.
- [ ] **Add [disko](https://github.com/nix-community/disko) to declaratively manage disk/partition creation for new installs and reinstalls.**

- work on secrets pre ragenix, stormd pre install for all the above bootstrapping steps would be ideal
- reduce home manager, make per user modules support instead
- Ensure my neovim undohistory/auto saves don't save `.age` files as they can be sensitive.

# Server hosts

simply run `deploy` in the host root and it will push changes to the server (or `deploy_[oracle|linode] <name>` from root)
