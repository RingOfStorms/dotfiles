{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.ringofstorms.tmux.aiNames = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Initial state of AI window/pane naming (tmux-ai-names, installed by the
      tmux NixOS module). Toggle at runtime with `prefix A` or
      `tmux set -g @ai_names on|off`.
    '';
  };

  # home manager doesn't give us an option to add tmux extra config at the top so we do it ourselves here.
  config.xdg.configFile."tmux/tmux.conf".text = lib.mkBefore (builtins.readFile ./tmux-reset.conf);

  config.programs.tmux = {
    enable = true;

    # Revisit this later, permission denied to make anything in `/run` as my user...
    secureSocket = false;

    # default is B switch to space for easier dual hand use
    shortcut = "Space";
    prefix = "C-Space";
    baseIndex = 1;
    mouse = true;
    keyMode = "vi";
    shell = "${pkgs.zsh}/bin/zsh";
    terminal = "tmux-256color";
    aggressiveResize = true;
    sensibleOnTop = false;

    # AI window/pane names (tmux-ai-names, from the tmux NixOS module). Placed
    # after plugins (mkAfter) so it overrides catppuccin's pane border format.
    extraConfig = ''
      # Window: AI name while automatic-rename is on; `prefix ,` locks a manual
      # name, `prefix <` returns the window to AI naming.
      set -g automatic-rename-format '#{?@window_ai_name,#{@window_ai_name},#{?pane_in_mode,[tmux],#{pane_current_command}}#{?pane_dead,[dead],}}'
      bind < set -wu automatic-rename

      # Panes: name in the top border, shown only when a window is split.
      set -g pane-border-format ' #{?@pane_name,#{@pane_name},#{pane_current_command}} '
      set-hook -g 'window-layout-changed[90]' 'set -wF pane-border-status "#{?#{e|>:#{window_panes},1},top,off}"'
      set-hook -g 'after-new-window[90]' 'set -wF pane-border-status "#{?#{e|>:#{window_panes},1},top,off}"'
      # `prefix .` locks a manual pane name; an empty name returns it to AI naming.
      bind . command-prompt -p "pane name (empty = auto):" { set -p @pane_name_input "%1" ; if -F "#{==:#{@pane_name_input},}" { set -pu @pane_name ; set -pu @pane_name_manual } { set -pF @pane_name "#{@pane_name_input}" ; set -p @pane_name_manual 1 } ; set -pu @pane_name_input }

      # Global on/off: `prefix A` or `tmux set -g @ai_names on|off`. Off (or
      # h001 down) leaves plain tmux names; nothing ever waits on the model.
      set -g @ai_names ${if config.ringofstorms.tmux.aiNames then "on" else "off"}
      bind A if -F '#{==:#{@ai_names},off}' { set -g @ai_names on ; display 'AI names: on' } { set -g @ai_names off ; display 'AI names: off' }
      # One detached namer per server (it exits with the server); -b + setsid
      # keep tmux startup from ever waiting on it.
      run-shell -b 'command -v tmux-ai-names >/dev/null && { setsid tmux-ai-names </dev/null >/dev/null 2>&1 & }; true'
    '';

    plugins = with pkgs.tmuxPlugins; [
      {
        plugin = catppuccin.overrideAttrs (_: {
          src = pkgs.fetchgit {
            url = "https://git.joshuabell.xyz/ringofstorms/tmux-catppuccin-coal.git";
            rev = "d078123cd81c0dbb3f780e8575a9d38fe2023e1b";
            sha256 = "sha256-qPY/dovDyut5WoUkZ26F2w3fJVmw4gcC+6l2ugsA65Y=";
          };
        });
        extraConfig = ''
          set -g @catppuccin_flavor 'mocha'
          set -g @catppuccin_window_left_separator ""
          set -g @catppuccin_window_right_separator " "
          set -g @catppuccin_window_middle_separator " █"
          set -g @catppuccin_window_number_position "right"
          set -g @catppuccin_window_default_fill "number"
          set -g @catppuccin_window_default_text "#W"
          set -g @catppuccin_window_current_fill "number"
          set -g @catppuccin_window_current_text "#W#{?window_zoomed_flag,(),}"
          set -g @catppuccin_status_modules_right "directory application date_time"
          set -g @catppuccin_status_modules_left "session"
          set -g @catppuccin_status_left_separator  " "
          set -g @catppuccin_status_right_separator " "
          set -g @catppuccin_status_right_separator_inverse "no"
          set -g @catppuccin_status_fill "icon"
          set -g @catppuccin_status_connect_separator "no"
          set -g @catppuccin_directory_text "#{b:pane_current_path}"
          set -g @catppuccin_date_time_text "%H:%M"
        '';
      }
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-strategy-nvim 'session'
          set -g @resurrect-capture-pane-contents 'on'
          # Hook to save tmux-resurrect state when a pane is closed
          set-hook -g pane-died "run-shell 'tmux-resurrect save'"
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '5' # minutes
        '';
      }
    ];
  };
}
