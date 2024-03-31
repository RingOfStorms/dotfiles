# First Install

- First follow nixos installation guide: https://nixos.wiki/wiki/NixOS_Installation_Guide
- Checkout this repo into /etc/nixos
- Before anything else, ensure the generated hardware-configuration is copied over into the desired HOSTNAME target in systems directory.
- switch into flake mode `nixos-rebuild switch --flake /etc/nixos#HOSTNAME`

- copy over this systems ssh public key pairs into the ./secrets/secrets.nix file - push those up, using another computer re-key all the secrets, push up again
  - pull new secrets down with new added keys

# Later updates

- `nix flake update /etc/nixos`
- `nixos-rebuild switch --flake /etc/nixos`

# Cleanup boot

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
