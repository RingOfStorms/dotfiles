# Steam: system-wide service state + per-user library/saves/compatdata
# /shader caches.
#
# .local/share/Steam is the multi-GB one (game installs, proton
# prefixes). .steam is just symlinks but Steam still expects them to
# exist across boots.
{
  system = {
    directories = [ "/var/lib/steam" ];
    files = [ ];
  };
  user = {
    directories = [
      ".local/share/Steam"
      ".steam"
    ];
    files = [ ];
  };
}
