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
      assertion = !(config.mods.de_cosmic.enable && config.mods.audio_pulse.enable);
      message = ''
        Configuration Error: cannot use pulse audio with cosmic.
        Remove: mods.audio_pulse.enable
      '';
    }
  ];
}
