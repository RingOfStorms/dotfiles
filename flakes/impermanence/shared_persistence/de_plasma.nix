# KDE Plasma 6 directory-level persistence.
#
# IMPORTANT: only DIRECTORIES here, never individual *rc files. KDE
# rewrites its config files via write-tmp-then-atomic-rename; that
# detaches a single-file bind mount and leaves the persisted copy
# stale/empty (nix-community/impermanence#192). Directory bind mounts
# survive atomic renames inside them.
#
# - .config/kdeconnect: paired-device list, identity cert
# - .local/share/kscreen: per-output monitor layout (hardware-specific,
#   not declarative through plasma-manager)
# - .config/plasma-workspace: session/autostart bookkeeping, ksmserver
# - .local/share/plasma: plasmoid/widget runtime data
# - .local/share/color-schemes: any custom (non-Nix-managed) color schemes
# - .local/share/baloo: Baloo file-indexer database
#
# .config/kwinoutputconfig.json is a single file (KWin's per-output
# config). It's written infrequently (only when you change monitor
# arrangement) so single-file persist is acceptable here.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [
      ".config/kdeconnect"
      ".local/share/kscreen"
      ".config/plasma-workspace"
      ".local/share/plasma"
      ".local/share/color-schemes"
      ".local/share/baloo"
    ];
    files = [
      ".config/kwinoutputconfig.json"
    ];
  };
}
