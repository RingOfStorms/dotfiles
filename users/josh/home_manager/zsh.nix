{ ... }:
{
  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;

    shellAliases = { };

    defaultKeymap = "emacs";

    profileExtra = ''
      # Make home/end and ctrl + left/right nav how I expect them to like in bash
      bindkey "\e[1~" beginning-of-line
      bindkey "\e[4~" end-of-line
      bindkey '^[[1;5D' emacs-backward-word
      bindkey '^[[1;5C' emacs-forward-word

      # Auto completion/suggestions/and case insensitivity
      autoload -Uz compinit && compinit
      setopt correct
      setopt extendedglob
      setopt nocaseglob
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'       # Case insensitive tab completion
      zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"       # Colored completion (different colors for dirs/files/etc)
      zstyle ':completion:*' rehash true                              # automatically find new executables in path
    '';
  };
}

