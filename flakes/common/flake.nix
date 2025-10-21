let
  utils = import ./utils.nix;
in
with utils;
{
  description = "Common NixOS configuration modules and Home Manager modules that require not other inputs beyond nixpkgs or home-manager itself. This is made by me for me and not designed to be general purpose for anyone else, but could be useful nontheless.";
  inputs = { };
  outputs =
    {
      ...
    }:
    {
      nixosModules = importAll ./nix_modules;
      homeManagerModules = importAll ./hm_modules;
    };
}
