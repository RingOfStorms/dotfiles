{ lib, pkgs, ... }:
{
  # home manager doesn't give us an option to add tmux extra config at the top so we do it ourselves here.
  xdg.configFile."tmux/tmux.conf".text = lib.mkBefore (builtins.readFile ./tmux-reset.conf);

  programs.tmux = {
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
          set -g @catppuccin_flavour 'mocha'
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

  home.shellAliases = {
    t = "tmux";
    tat = "tmux attach-session";
  };
}
