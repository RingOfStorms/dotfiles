{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "homeManager"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      users = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
        description = "Home manager users to configure. Should match nix options of home-manager.users.<name>.*";
      };
      stateVersion = lib.mkOption {
        type = lib.types.str;
        default = "23.11";
        description = "Home manager state version";
      };
    };
  config = {
    # Home manager options
    security.polkit.enable = true;
    home-manager.useUserPackages = true;
    home-manager.useGlobalPkgs = true;
    home-manager.backupFileExtension = "bak";

    home-manager.users = lib.mapAttrs' (name: userConfig: {
      inherit name;
      value = userConfig // {
        home.stateVersion = cfg.stateVersion;
        programs.home-manager.enable = true;
        home.username = name;
        home.homeDirectory = lib.mkForce "/home/${name}";
      };
    }) cfg.users;
  };
}
