{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "users"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  top_cfg = config.${ccfg.custom_config_key};
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      admins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "josh" ];
        description = ''
          List of users to be added to the system.
        '';
      };
      primary = lib.mkOption {
        type = lib.types.str;
        default = lib.optionalString (cfg.admins != [ ] && cfg.admins != null) (
          builtins.elemAt cfg.admins 0
        );
        description = "The primary user of the system.";
      };
      users = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
        description = "Normal users to configure (not for system users). Should match nix options of users.userser.<name>.*";
      };
    };
  config = {
    users.users = lib.mapAttrs (
      name: userConfig:
      userConfig
      // {
        inherit name;
        isNormalUser = lib.mkIf name != "root" true;
        initialPassword =
          if (lib.hasAttr "initialPassword" userConfig) then userConfig.initialPassword else "password1";
        extraGroups =
          lib.optionals (builtins.elem name cfg.admins) [ "wheel" ] ++ (userConfig.extraGroups or [ ]);
      }
    ) cfg.users;

    programs.nh.flake = lib.mkIf (lib.hasAttr "primary" cfg) "/home/${cfg.primary}/.config/nixos-config/hosts/${top_cfg.systemName}";
  };
}
