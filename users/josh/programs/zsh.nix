{ ... }:
{
  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;

    shellAliases = { };

    profileExtra = ''
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

