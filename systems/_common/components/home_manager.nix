{ config, lib, pkgs, settings, ylib, ... } @ inputs:
let
  home-manager = builtins.fetchTarball {
    url = "https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz";
    # to get hash run `nix-prefetch-url --unpack "https://github.com/nix-community/home-manager/archive/release-23.11.tar.gz"`
    sha256 = "0g51f2hz13dk953i501fmc6935difhz60741nypaqwz127hy5ldk";
  };
in
{
  imports =
    [
      # home manager import
      (import "${home-manager}/nixos")
    ];
  # Home manager options
  security.polkit.enable = true;
  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = { inherit settings; inherit ylib; inherit (inputs) ragenix; inherit (config) age; };
}


