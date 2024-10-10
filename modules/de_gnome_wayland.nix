{
  config,
  lib,
  ...
}:
with lib;
let
  name = "de_gnome_wayland";
  cfg = config.my_modules.${name};
in
{
  options = {
    my_modules.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable GNOME with wayland desktop environment");
    };
  };

  config = mkIf cfg.enable {
    # TODO
  };
}
