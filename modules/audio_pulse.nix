{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  name = "audio";
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
    # sound.enable = true;
    # services.pipewire.pulse.enable = false;
    # services.pipewire.enable = false;
    # services.pipewire.audio.enable =false;
    # hardware.pulseaudio.enable = true;
    # hardware.pulseaudio.package = pkgs.pulseaudioFull;
    # environment.systemPackages = [ pkgs.pavucontrol ];

    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      # If you want to use JACK applications, uncomment this
      #jack.enable = true;
    };
  };
}
