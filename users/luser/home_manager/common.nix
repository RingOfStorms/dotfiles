{ lib, ylib, settings, ... }:
{
  imports = [
    (settings.usersDir + "/_common/components/home_manager/tmux/tmux.nix")
    (settings.usersDir + "/_common/components/home_manager/atuin.nix")
    (settings.usersDir + "/_common/components/home_manager/starship.nix")
    (settings.usersDir + "/_common/components/home_manager/zoxide.nix")
    (settings.usersDir + "/_common/components/home_manager/zsh.nix")
  ];
}


