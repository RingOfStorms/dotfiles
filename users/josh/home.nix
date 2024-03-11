{ pkgs, lib, settings, ... } @ args:
let
  # TODO update to be in this config normally
  # cursor fix? https://github.com/wez/wezterm/issues/1742#issuecomment-1075333507
  weztermConfig = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/RingOfStorms/setup/72635c6674540bfefa2325f69e6ee6de9a11a62b/home/dotfiles/wezterm.lua";
    sha256 = "sha256-kwbg9S9IHhAw6RTPvRjqGew5qz8a8VxjqonkgEKGtys=";
  };
  tmux = pkgs.tmuxPlugins;
in
{
  imports = [
    (settings.usersDir + "/_common/home.nix")
  ];
  home.packages = with pkgs; [
    firefox-esr
    wezterm
    vivaldi
    ollama

    # Desktop Environment stuff
    wofi # app launcher TODO configure this somehow
    gnome.dconf-editor # use `dump dconf /` before and after and diff the files for easy editing of dconf below
    gnomeExtensions.workspace-switch-wraparound
    #gnome.gnome-tweaks
    #gnomeExtensions.forge # probably dont need on this on tiny laptop but may explore this instead of sway for my desktop
  ];

  home.file.".wezterm.lua".source = weztermConfig; # todo actual configure this in nix instead of pulling from existing one. Maybe lookup the more official home manager dotfile solutions instead of inline
  home.file.".psqlrc".text = ''
    \pset pager off
  '';

  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;
  };
  # home manager doesn't give us an option to add tmux extra config at the top so we do it ourselves here.
  xdg.configFile."tmux/tmux.conf".text = lib.mkBefore ''
    # Reset everything then add what we want exactly
    unbind-key -a

    # Window stuff
    bind -r H previous-window
    bind -r L next-window
    bind -r 1 select-window -t:1
    bind -r 2 select-window -t:2
    bind -r 3 select-window -t:3
    bind -r 4 select-window -t:4
    bind -r 5 select-window -t:5
    bind -r 6 select-window -t:6
    bind -r 7 select-window -t:7
    bind -r 8 select-window -t:8
    bind -r 9 select-window -t:9
    bind r command-prompt "rename-window %%"
    bind | split-window -h -c "#{pane_current_path}"
    bind \\ split-window -v -c "#{pane_current_path}"
    bind t new-window
    bind T command-prompt -p "window name:" "new-window; rename-window '%%'"
    bind m command-prompt -p "Swap with window index:" "swap-window -t '%%'"
    bind -r [ swap-window -t -1 \; previous-window
    bind -r ] swap-window -t +1 \; next-window

    # Sessions
    bind C-s command-prompt -p "session name:" "new-session -s '%%'"
    bind C-r command-prompt "rename-session %%"
    bind -r C-L switch-client -n
    bind -r C-H switch-client -p

    # Pane stuff
    bind -r h select-pane -L
    bind -r j select-pane -D
    bind -r k select-pane -U
    bind -r l select-pane -R
    bind -r , resize-pane -L 20
    bind -r . resize-pane -R 20
    bind -r - resize-pane -D 7
    bind -r = resize-pane -U 7
    bind q kill-pane
    bind w kill-window
    bind x swap-pane -D

    # Tmux util
    bind p paste-buffer
    bind X source-file ~/.config/tmux/tmux.conf
    bind z resize-pane -Z
    bind : command-prompt
    bind ^Q detach

    # ==========
    # My options
    set-option -g terminal-overrides ',xterm-256color:RGB'
    set -g detach-on-destroy off
    set -g renumber-windows on
    set -g status-position top
  '';
  programs.tmux = {
    enable = true;

    # Revisit this later, permission denied to make anything in run as my user...
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
  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
    flags = [ "--disable-up-arrow" ];
    settings = {
      workspaces = true;
      exit-mode = "return-query";
      enter_accept = true;
    };
  };
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      add_newline = false;
      palette = "catppuccin_coal";
      palettes.catppuccin_coal = import "${settings.commonDir}/catppuccin_coal.nix";
    };
  };
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
    options = [ "--cmd cd" ];
  };

  dconf = {
    enable = true;
    settings = (import ./gnome_settings.nix args);
  };

  gtk = {
    enable = true;

    cursorTheme = {
      name = "Numix-Cursor";
      package = pkgs.numix-cursor-theme;
    };

    gtk3.extraConfig = {
      Settings = ''
        	gtk-application-prefer-dark-theme=1
      '';
    };

    gtk4.extraConfig = {
      Settings = ''
        	gtk-application-prefer-dark-theme=1
      '';
    };
  };

  home.sessionVariables.GTK_THEME = "palenight";

}
