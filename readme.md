## TODO working on changes to this now

### Old Config prior to per system flake approach

<https://git.joshuabell.xyz/dotfiles/~files/6527f67145fe047df57b4778c154dde580ec04c4>

# First Install on new Machine

## NixOS install

1. Install nix minimal:

- Partitions
  - <https://nixos.org/manual/nixos/stable/#sec-installation>
  - <https://nixos.wiki/wiki/NixOS_Installation_Guide#Swap_file>
  - `parted /dev/DEVICE -- mklabel gpt` - make GPT partition table
  - `parted /dev/DEVICE -- mkpart NIXROOT ext4 2GB 100%` - make root partition (2GB offset for boot)
  - `parted /dev/DEVICE -- mkpart ESP fat32 1MB 2GB` - make boot partition (2GB)
  - `parted /dev/DEVICE -- set 2 esp on` - make boot bootable
- Formatting
  - `mkfs.ext4 -L NIXROOT /dev/DEVICE_1` - root ext4
  - `mkfs.fat -F 32 -n NIXBOOT /dev/DEVICE_2` - boot FAT
- Mount
  - `mount /dev/disk/by-label/NIXROOT /mnt`
  - `mkdir -p /mnt/boot`
  - `mount -o umask=077 /dev/disk/by-label/NIXBOOT /mnt/boot`
(Note that swap files is defined in nix config later not needed at this stage)

- nixos config and hardware config
  - `export HOSTNAME=desired_hostname_for_this_machine`
  - `export USERNAME=desired_username_for_admin_on_this_machine` (josh)
  - `nixos-generate-config --root /mnt`
  - `cd /mnt/etc/nixos`
  - `curl -O https://share.joshuabell.link/nix/onboard.sh`
  - `chmod +x onboard.sh && ./onboard.sh`
  - verify hardware config, run `nixos-install`
  - `reboot`
- log into USERNAME with `password1`, use `passwd` to change the password

> Easiest to ssh into the machine for these steps so you can copy paste...

- `cat /etc/ssh/ssh_host_ed25519_key.pub ~/.ssh/id_ed25519.pub`
  - On an already onboarded computer copy these and add them to secrets/secrets.nix file
  - Rekey secrets: `nix run github:yaxitech/ragenix -- --rules ~/.config/nixos-config/secrets/secrets.nix -r`
  - Maybe copy hardware/configs over and setup, otehrwise do it on the client machine
- git clone nixos-config `git clone https://git.joshuabell.xyz/dotfiles ~/.config/nixos-config`
- Setup config as needed
  - top level flake.nix additions
  - add hosts dir and files needed
- `sudo nixos-rebuild switch --flake ~/.config/nixos-config`
- Update remote, ssh should work now: `cd ~/.config/nixos-config && git remote remove origin && git remote add origin "ssh://git.joshuabell.xyz:3032/dotfiles" && git pull origin master`

## Local tooling

- firefox/1password setup
  - sign in to firefox
  - sign into 1 password ext

- atuin setup
  - if atuin is on enable that mod in configuration.nix, make sure to `atuin login` get key from existing device
  - TODO move key into secrets and mount it to atuin local share
- stormd onboard to network
- ssh key access, ssh iden in config in nix config
-

## Darwin

- TODO

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

- on new cosmic the bar is shown can i have this hidden by default
- Split config into further flakes, inputs should not affect other systems, like first run without stormd
- work on secrets pre ragenix, stormd pre install for all the above bootstrapping steps would be ideal
- reduce home manager, make per user modules support instead
- Ensure my neovim undohistory/auto saves don't save `.age` files as they can be sensitive.
- can I get tmux `tat` attach to remove new window if it restored from saved session?
