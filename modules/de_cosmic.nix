{
  cosmic,
  config,
  lib,
  settings,
  ...
}:
with lib;
let
  # name = "de_cosmic";
  # cfg = config.my_modules.${name};
in
{

  options = {
    my_modules.de_cosmic = {
      enable = mkEnableOption (lib.mdDoc "Enable COSMIC desktop environment");
    };
  };

  # Import the module from nix flake https://github.com/lilyinstarlight/nixos-cosmic
  imports = optional settings.uses_cosmic cosmic.nixosModules.default;

  config = mkIf config.my_modules.de_cosmic.enable {
    # Use cosmic binary cache
    nix.settings = {
      substituters = [ "https://cosmic.cachix.org/" ];
      trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
    };

    services.desktopManager.cosmic.enable = true;
    services.displayManager.cosmic-greeter.enable = true;
  };
}
