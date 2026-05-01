# tmux-resurrect saved session state.
#
# tmux-resurrect (with the upstream default `@resurrect-dir`) writes
# under ~/.tmux/resurrect, not the XDG ~/.local/share/tmux path. The
# XDG dir is kept in the list as well so any future relocation (or
# other tmux state landing there) survives reboots too.
{
  system = {
    directories = [ ];
    files = [ ];
  };
  user = {
    directories = [
      ".tmux"
      ".local/share/tmux"
    ];
    files = [ ];
  };
}
