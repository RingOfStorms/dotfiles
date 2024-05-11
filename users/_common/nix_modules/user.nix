{ pkgs, settings, ... }:
{
  users.users.${settings.user.username} = {
    initialPassword = "password1";
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "input" ];
    shell = pkgs.zsh;
  };

  environment.pathsToLink = [ "/share/zsh" ];
  programs.zsh = {
    enable = true;
  };
}
