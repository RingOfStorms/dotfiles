## TODO working on changes to this now

# First Install on new Machine

## NixOS
export HOSTNAME=desired_hostname_for_this_machine (___)
export USERNAME=desired_username_for_admin_on_this_machine (josh)
- Follow nixos installation guide: https://nixos.wiki/wiki/NixOS_Installation_Guide
    - Follow until the config is generated
- `curl -O https://share.joshuabell.link/nix/onboard.sh && chmod +x onboard.sh && ./onboard.sh`
- `reboot`
- log into USERNAME with `password1`, use `passwd` to change the password


- `cat /etc/ssh/ssh_host_ed25519_key.pub ~/.ssh/id_ed25519.pub`
    - On an already onboarded computer copy these and add them to secrets/secrets.nix file
    - Rekey secrets: `nix run github:yaxitech/ragenix -- --rules ~/.config/nixos-config/secrets/secrets.nix -r`
    - Maybe copy hardware/configs over and setup, otehrwise do it on the client machine
- git clone nixos-config `git clone https://github.com/RingOfStorms/dotfiles.git ~/.config/nixos-config`
- Setup config as needed
    - top level flake.nix additions
    - add hosts dir and files needed
- `sudo nixos-rebuild switch --flake ~/.config/nixos-config`
- Update remote, ssh should work now: `cd ~/.config/nixos-config && git remote remove origin && git remote add origin "git@github.com:RingOfStorms/dotfiles.git" && git pull origin master`

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

# Settings references:

- Flake docs: https://nixos.wiki/wiki/Flakes
- nixos: https://search.nixos.org/options
- home manager: https://nix-community.github.io/home-manager/options.xhtml
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
- make sure all my aliases are accounted for, still missing things like rust etc: https://github.com/RingOfStorms/setup
- add in copy paste support with xclip or nix equivalent
