{ config, pkgs, home-manager, settings, ylib, ... } @ inputs:
# Note that we must have the channel added for the import to work below
# `sudo nix-channel --add https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz home-manager`
# `sudo nix-channel --update`
{
  imports =
    [
      # home manager import
      home-manager.nixosModules.home-manager
      # home-manager
    ];
  # Home manager options
  security.polkit.enable = true;
  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = { inherit settings; inherit ylib; inherit (inputs) ragenix; inherit (config) age; };
}

