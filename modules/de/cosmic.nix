{
  cosmic,
  config,
  lib,
  pkgs,
  settings,
  ...
}:
with lib;
let
  name = "de_cosmic";
  cfg = config.mods.${name};
in
{

  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable COSMIC desktop environment");
    };
  };

  config = mkIf cfg.enable {
    # Use cosmic binary cache
    nix.settings = {
      substituters = [ "https://cosmic.cachix.org/" ];
      trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
    };

    # Enable cosmic
    services.desktopManager.cosmic.enable = true;
    services.displayManager.cosmic-greeter.enable = true;
    environment.cosmic.excludePackages = with pkgs; [ cosmic-edit cosmic-term cosmic-store ];
  };
}
