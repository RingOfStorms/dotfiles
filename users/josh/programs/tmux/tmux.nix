{ settings, lib, pkgs, ... } @ args:
let
  tmux = pkgs.tmuxPlugins;
in
{
  # home manager doesn't give us an option to add tmux extra config at the top so we do it ourselves here.
  xdg.configFile."tmux/tmux.conf".text = lib.mkBefore (builtins.readFile ./tmux-reset.conf);

  programs.tmux = {
    enable = true;

    # Revisit this later, permission denied to make anything in `/run` as my user...
    secureSocket = false;

    shortcut = "a";
    prefix = "C-a";
    baseIndex = 1;
    mouse = true;
    keyMode = "vi";
    newSession = true;
    shell = "${pkgs.zsh}/bin/zsh";
    terminal = "screen-256color";
    aggressiveResize = true;

    plugins = [
      {
        plugin = tmux.sessionist;
        extraConfig = ''
          set -g @sessionist-join-pane "j"
          set -g @sessionist-goto "o"

          set -g @default_key_bindings_new "UNSET"
        '';
      }
      tmux.yank
      tmux.tmux-thumbs
      {
        plugin = tmux.fzf-tmux-url;
        extraConfig = ''
          set -g @fzf-url-fzf-options '-p 60%,30% --prompt = "   " - -border-label=" Open URL "'
          set -g @fzf-url-history-limit '2000'
        '';
      }
      {
        plugin = tmux.catppuccin.overrideAttrs (_: {
          src = pkgs.fetchFromGitHub {
            owner = "ringofstorms";
            repo = "tmux-catppuccin-coal";
            rev = "e6d7c658e2d11798912ca1ed4e3626e3e1fad3fc";
            sha256 = "sha256-M1XAeCz/lqgjZ7CnWCykJxZCDk+WVoawwHrR9SEO9ns=";
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
    ];
  };

  home.shellAliases = {
    t = "tmux";
    tat = "tmux ls 2>/dev/null && tmux attach-session -t \"$(tmux ls | head -n1 | cut -d: -f1)\" || tmux new-session";
  };
}

