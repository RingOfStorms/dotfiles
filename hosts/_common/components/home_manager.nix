{
  config,
  settings,
  ylib,
  ...
}@inputs:
let
  home-manager = settings.home-manager;
in
{
  imports = [ home-manager.nixosModules.home-manager ];

  # Home manager options
  security.polkit.enable = true;
  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = {
    inherit settings;
    inherit ylib;
    inherit (inputs) ragenix;
    inherit (config) age;
  };
}
