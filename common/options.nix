{
  config,
  lib,
  ...
}:
let
  ccfg = import ./config.nix;
  cfg_path = "${ccfg.custom_config_key}";
  cfg = config.${cfg_path};
in
{
  options.${cfg_path} = {
    systemName = lib.mkOption {
      type = lib.types.str;
      description = "The name of the system.";
    };
  };
}
