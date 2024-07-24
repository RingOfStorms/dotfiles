{ pkgs, ... }:
{
  # Enable sound.
  hardware.pulseaudio.enable = true;
  hardware.pulseaudio.package = pkgs.pulseaudioFull;
  environment.systemPackages = [ pkgs.pavucontrol ];
}
