{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = "${ccfg.custom_config_key}".users;
  cfg = config.${cfg_path};
  top_cfg = config."${ccfg.custom_config_key}";
in
{
  option.${cfg_path} = {
    adminUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "josh" ];
      description = ''
        List of users to be added to the system.
      '';
    };
    primaryUser = lib.mkOption {
      type = lib.types.str;
      default = lib.optionalString (cfg.adminUsers != [ ] && cfg.adminUsers != null) (
        builtins.elemAt cfg.adminUsers 0
      );
      description = "The primary user of the system.";
    };
    users = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Normal* users to configure (not for system users). Should match nix options of users.userser.<name>.*";
    };
  };
  config =
    {
      users.users = lib.mapAttrs (
        name: config:
        {
          inherit name;
          isNormalUser = true;
        }
        // config
      ) cfg.users;

      programs.nh.flake = "/home/${cfg.primaryUser}/.config/nixos-config/hosts/${top_cfg.systemName}";
    }
    // lib.map (name: {
      users.users.${name} = {
        extraGroups = [ "wheel" ];
      };
    }) cfg.adminUsers;
}
