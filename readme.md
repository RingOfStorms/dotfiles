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
- git clone nixos-config `git clone https://github.com/RingOfStorms/dotfiles.git ~/.config/nixos-config`
- `sudo nixos-rebuild switch --flake ~/.config/nixos-config`
- Update remote, ssh should work now: `cd ~/.config/nixos-config && git remote remove origin && git remote add origin "git@github.com:RingOfStorms/dotfiles.git" && git pull origin master`

- TODO ONBOARD NEW MACHINE CONFIGS, secrets, etc
    - use hostname to make new folders in the repo, copy hardware config, and create config from template. Update flake.nix with top level info needed for this system with ARCH detected.
    - Copy public keys into secrets.nix file
        - `cat /etc/ssh/ssh_host_ed25519_key.pub ~/.ssh/id_ed25519.pub`
    - `git commit -a  --author="Bot <bot@joshuabell.dev>" --email="bot@joshuabell.dev" -m "secrets update"`
        
    - rekey system with another onboarded device... (make this offlinable?), push there, pull here
- `sudo nixos-rebuild switch --flake ~/.config/nixos-config`
- reboot? done



## Darwin
- TODO

###
###
###
###
###


# First Install on new Machine

- First follow nixos installation guide: https://nixos.wiki/wiki/NixOS_Installation_Guide
    - Follow up to generate config command
- in hardware-configuration.nix
    - change to use by-labels made in nixos installation guide (optional but nice for updating device in the future)
- in configuration.nix
    - set networking.hostname to HOSTNAME
    - enable networkmanager
    - uncomment systemPackages and add: git curl
    - add `nix.settings.experimental-features = [ "nix-command" "flakes" ];`
- Install nixos: `cd /mnt` `sudo nixos-install`
- `passwd` to change root password (if not already prompted to do so)
- `reboot`

-- TODO come up with a way to pregen keys so onboarding is less stupid with secrets?

- `cp -r /etc/nixos ~/nixos_bak` Backup configuration
- Checkout this repo into /etc/nixos: `rm -rf /etc/nixos` `git clone https://github.com/ringofstorms/dotfiles /etc/nixos`
- Copy the backup into the new /etc/nixos/hosts/HOSTNAME dir `mkdir /etc/nixos/hosts/HOSTNAME && cp -r ~/nixos_bak/* /etx/nixos/hosts/HOSTNAME`
- copy the existing configuration/other configuration nix of an existing system and edit it to desires state. [[ TODO make this step cleaner/easier... ]]
- switch into flake mode `nixos-rebuild switch --flake /etc/nixos[#HOSTNAME]` and switch to new system
- Add this host to the top level `flake.nix` myHosts section
- copy system ssh public key and create a key for user and copy those into the nixos secrets.nix file
    - `cat /etc/ssh/ssh_host_ed25519_key.pub`
    - `cat ~/.ssh/id_ed25519.pub`
- Push changes to remote using temp user password
- rekey secrets with any other onboarded system
    - TODO
- copy over this host's ssh public key ( /etc/shh/*ed25519* ) into the ./secrets/secrets.nix file - push those up, using another computer re-key all the secrets, push up again
  - pull new secrets down with new added keys and rebuild

- clone neovim setup...

# Later updates

- `nix flake update /etc/nixos`
- `nixos-rebuild switch --flake /etc/nixos`

# Cleanup boot

> TODO remove, no longer needed `nh` handles this

I used the existing windows 100MB boot partition and it fills up constantly. Have to purge old stuff a lot this is how:

- `find '/boot/loader/entries' -type f ! -name 'windows.conf' | head -n -4 | xargs -I {} rm {}; nix-collect-garbage -d; nixos-rebuild boot; echo; df`

# Settings references:

- Flake docs: https://nixos.wiki/wiki/Flakes
- nixos: https://search.nixos.org/options
- home manager: https://nix-community.github.io/home-manager/options.xhtml
  TODO make an offline version of this, does someone else have this already?

# TODO

- Secret management?
  - ssh keys for github/etc
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
