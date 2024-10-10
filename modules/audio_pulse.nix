{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  name = "audio_pulse";
  cfg = config.mods.${name};
in
{
  options = {
    mods.${name} = {
      enable = mkEnableOption (lib.mdDoc "Enable ${name}");
    };
  };

  config = mkIf cfg.enable {
    # Enable sound.
    hardware.pulseaudio.enable = true;
    hardware.pulseaudio.package = pkgs.pulseaudioFull;
    environment.systemPackages = [ pkgs.pavucontrol ];
  };
}
