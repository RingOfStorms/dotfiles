# Flatpak: system-wide installs + runtime, per-user installs, and
# per-app data (~/.var/app/<id>).
{
  system = {
    directories = [ "/var/lib/flatpak" ];
    files = [ ];
  };
  user = {
    directories = [
      ".local/share/flatpak"
      ".var/app"
    ];
    files = [ ];
  };
}
