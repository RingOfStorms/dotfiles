{ pkgs, settings, ... }:
{
  users.users.${settings.user.username} = {
    initialPassword = "password1";
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "input" ];
    shell = pkgs.zsh;
  };

  # TODO how to do this from home manager file instead
  environment.pathsToLink = [ "/share/zsh" ];
  programs.zsh = {
    enable = true;
  };
}

