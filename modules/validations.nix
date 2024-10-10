{ lib, config, ... }:
{
  # config.assertions = [
  #   {
  #     assertion =
  #       lib.length (
  #         lib.filter (x: x) [
  #           config.my_modules.de_cosmic.enable
  #           config.my_modules.de_gnome_xorg.enable
  #           config.my_modules.de_gnome_wayland.enable
  #         ]
  #       ) <= 1;
  #     message = ''
  #       Configuration Error: Multiple desktop environments are enabled.
  #       Please enable only one of the following:
  #         - my_modules.de_cosmic.enable
  #         - my_modules.de_gnome_xorg.enable
  #         - my_modules.de_gnome_wayland.enable
  #     '';
  #   }
  # ];
}
