{ pkgs, ... }:
{
  # Enable sound.
  sound.enable = true;
  hardware.pulseaudio.enable = true;
  hardware.pulseaudio.package = pkgs.pulseaudioFull;
  environment.systemPackages = [ pkgs.pavucontrol ];
}
