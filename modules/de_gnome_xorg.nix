{
  config,
  lib,
  ...
}:
with lib;
let
  name = "de_gnome_xorg";
  cfg = config.my_modules.${name};
in
{
  options = {
    my_modules.${name} = {
      enable = mkEnableOption "Enable GNOME with wayland desktop environment";
    };
  };

  config = mkIf cfg.enable {
    # TODO
  };
}

