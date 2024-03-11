# First Install

- Before anything else, ensure the generated hardware-configuration is copied over into the desired hostname target in systems directory.
- //todo add experimental whatevers `nixos-rebuild switch --flake /etc/nixos#gpdPocket3`

# Later updates

- `nix flake update /etc/nixos`
- `nixos-rebuild switch --flake /etc/nixos`

# Cleanup boot

I used the existing windows 100MB boot partition and it fills up constantly. Have to purge old stuff a lot this is how:

- `find '/boot/loader/entries' -type f | head -n -4 | xargs -I {} rm {}; nix-collect-garbage -d; nixos-rebuild boot; echo; df`

# Settings references:

- Flake docs: https://nixos.wiki/wiki/Flakes
- nixos: https://search.nixos.org/options
- home manager: https://nix-community.github.io/home-manager/options.xhtml
  TODO make an offline version of this, does someone else have this already?


# TODO
- Use top level split out home manager configurations instead of the one built into the system config...
- get dot files setup better (see todo comment on wezterm config)
- Make a flake for neovim and move out some system packages required for that into that flake, re-use for root and user rather than cloning each place?
- 
