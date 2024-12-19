## TODO working on changes to this now

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
- Mount + swapfile
  - `mount /dev/disk/by-label/NIXROOT /mnt`
  - `mkdir -p /mnt/boot`
  - `mount -o umask=077 /dev/disk/by-label/NIXBOOT /mnt/boot`

# TODO swap may nto be needed anymore, this can just be added to hardware config and nixos will make it itself... <https://discourse.nixos.org/t/how-to-add-a-swap-after-nixos-installation/41742/2>

- `dd if=/dev/zero of=/mnt/.swapfile bs=1024 count=2097152` (2GiB size, 2.14..GB) - make swap, count=62500000 (64GB)
- `chmod 600 /mnt/.swapfile`
- `mkswap /mnt/.swapfile`
- `swapon /mnt/.swapfile`
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
- `nixos-rebuild switch --flake ~/.config/nixos-config`
- Update remote, ssh should work now: `cd ~/.config/nixos-config && git remote remove origin && git remote add origin "ssh://git.joshuabell.xyz:3032/dotfiles" && git pull origin master`

## Local tooling

- stormd
  - get stormd and build locally, copy release build to /etc/stormd
  - enable stormd mod TODO LEFT OFF HERE... get this working on lio
- atuin setup
  - if atuin is on enable that mod in configuration.nix, make sure to `atuin login` get key from existing device
  - TODO move key into secrets and mount it to atuin local share

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

###

###

- clone neovim setup...

# Settings references

- Flake docs: <https://nixos.wiki/wiki/Flakes>
- nixos: <https://search.nixos.org/options>
- home manager: <https://nix-community.github.io/home-manager/options.xhtml>
  TODO make an offline version of this, does someone else have this already?

# TODO

- Use top level split out home manager configurations instead of the one built into the system config...
- Make a flake for neovim and move out some system packages required for that into that flake, re-use for root and user rather than cloning each place?
- EDITOR env var set to neovim
- gif command from video

```sh
gif () {
  if [[ -z $1 ]]; then
    echo "No gif specified"
    return 1
  fi
  ffmpeg -i $1 -filter_complex "fps=7,scale=iw:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=32[p];[s1][p]paletteuse=dither=bayer" $1".gif"
}
```

- Ensure my neovim undohistory/auto saves don't save `.age` files as they can be sensitive.
- make sure all my aliases are accounted for, still missing things like rust etc: <https://github.com/RingOfStorms/setup>
- add in copy paste support with xclip or nix equivalent
