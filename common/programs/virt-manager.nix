{
  config,
  lib,
  ...
}:
let
  ccfg = import ../config.nix;
  cfg_path = [
    ccfg.custom_config_key
    "programs"
    "virt-manager"
  ];
  cfg = lib.attrsets.getAttrFromPath cfg_path config;
  users_cfg = config.${ccfg.custom_config_key}.users;
in
{
  options =
    { }
    // lib.attrsets.setAttrByPath cfg_path {
      enable = lib.mkEnableOption "Enable virt manager/quemu";
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = builtins.attrNames users_cfg;
        description = "Users to configure for virt-manager.";
      };
    };

  config = lib.mkIf cfg.enable {
    services.qemuGuest.enable = true;
    services.spice-vdagentd.enable = true;
    programs.virt-manager = {
      enable = true;
    };

    virtualisation = {
      libvirtd.enable = true;
      spiceUSBRedirection.enable = true;
    };

    users.groups.libvirtd.members = cfg.users;
  };
}
