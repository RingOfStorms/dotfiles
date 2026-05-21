{ ... }:
{
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;

    shellAliases = { };

    defaultKeymap = "emacs";

    # Ephemeral history: keep an in-memory list for up-arrow within a session,
    # but never persist to disk. Atuin is the source of truth for history.
    history = {
      size = 10000;     # in-memory entries available to up-arrow this session
      save = 0;         # never save any entries to HISTFILE
      share = false;    # don't share history between concurrent sessions
      append = false;   # don't append to HISTFILE on exit
      extended = false;
      ignoreAllDups = true;
    };

    initContent = ''
      # Set editor to neovim, TODO only do this if mod.neovim is enabled
      export EDITOR=nvim
      export VISUAL=nvim

      # --- Ephemeral shell history (atuin is the only persistent store) ---
      # Home Manager always sets HISTFILE; unset it so zsh has nowhere to write.
      # Also belt-and-braces unset any incremental-write options that other
      # init files (oh-my-zsh, /etc/zshrc, atuin's zsh init) might have set.
      unset HISTFILE
      unsetopt SHARE_HISTORY
      unsetopt INC_APPEND_HISTORY
      unsetopt INC_APPEND_HISTORY_TIME
      unsetopt APPEND_HISTORY
      # ---------------------------------------------------------------------

      # Enable editing command in external editor
      autoload -Uz edit-command-line
      zle -N edit-command-line
      # fix delete key
      bindkey "^[[3~" delete-char
      # Try multiple bindings for edit-command-line
      bindkey '^X^E' edit-command-line    # Traditional Ctrl+X,Ctrl+E binding
      bindkey '^[^M' edit-command-line    # Alt+Enter
      # Note: Ctrl+Enter might not be distinctly capturable in all terminals

      # Make home/end and ctrl + left/right nav how I expect them to like in bash
      bindkey "\e[1~" beginning-of-line
      bindkey "\e[4~" end-of-line
      bindkey '^[[1;5D' emacs-backward-word
      bindkey '^[[1;5C' emacs-forward-word
      # Also support Ctrl+h/l for word movement
      bindkey '^H' emacs-backward-word
      bindkey '^L' emacs-forward-word

      # Auto completion/suggestions/and case insensitivity
      autoload -Uz compinit && compinit

      # Register completions for functions defined in environment.shellInit
      # (which runs before compinit, so compdef calls there are too early)
      compdef _flake_complete flake 2>/dev/null || true

      setopt correct
      setopt extendedglob
      setopt nocaseglob
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'       # Case insensitive tab completion
      zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"       # Colored completion (different colors for dirs/files/etc)
      zstyle ':completion:*' rehash true                              # automatically find new executables in path
    '';
  };
}
