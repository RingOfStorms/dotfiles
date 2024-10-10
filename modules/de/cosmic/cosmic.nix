{
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

  cosmicConfigDir = ./config;
  cosmicFiles = builtins.attrNames (builtins.readDir cosmicConfigDir);
  cosmicConfigFiles = map (fileName: {
    name = "cosmic/${fileName}";
    value = {
      source = "${cosmicConfigDir}/${fileName}";
      # enable = true;
    };
  }) cosmicFiles;
  cosmicConfigFilesAttrs = builtins.listToAttrs cosmicConfigFiles;
in
{

  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable COSMIC desktop environment");
      nvidiaExtraDisplayFix = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable extra display fix for nvidia cards.
        '';
      };
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
    environment.cosmic.excludePackages = with pkgs; [
      cosmic-edit
      cosmic-term
      cosmic-store
    ];

    boot.kernelParams = mkIf cfg.nvidiaExtraDisplayFix [
      "nvidia_drm.fbdev=1"
    ];

    # Config
    # home-manager.backupFileExtension = "bak";
    # home-manager.users.${settings.user.username} = {
    #   xdg.configFile = cosmicConfigFilesAttrs;
    # };
  };

}
