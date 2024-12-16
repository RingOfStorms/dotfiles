{ lib, config, ... }:
{
  config.assertions = [
    {
      assertion =
        lib.length (
          lib.filter (x: x) [
            config.mods.de_cosmic.enable
            config.mods.de_gnome_xorg.enable
            config.mods.de_gnome_wayland.enable
          ]
        ) <= 1;
      message = ''
        Configuration Error: Multiple desktop environments are enabled.
        Please enable only one of the following:
          - mods.de_cosmic.enable
          - mods.de_gnome_xorg.enable
          - mods.de_gnome_wayland.enable
      '';
    }
    {
      # // TODO check sinc epoulse is no longer
      assertion = !(config.mods.de_cosmic.enable && config.mods.audio.enable);
      message = ''
        Configuration Error: cannot use audio with cosmic. Check if this is true anymore...
        Remove: mods.audio.enable
      '';
    }
  ];
}
