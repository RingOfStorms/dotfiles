# PipeWire/WirePlumber audio device state — Bluetooth codec selection,
# per-device volumes, default sink/source picks. PulseAudio compat dir
# included for apps that still talk to the legacy socket name.
{
  system = {
    directories = [ "/var/lib/pipewire" ];
    files = [ ];
  };
  user = {
    directories = [
      ".config/pulse"
      ".local/state/wireplumber"
    ];
    files = [ ];
  };
}
