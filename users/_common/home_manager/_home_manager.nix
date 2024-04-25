{ settings, pkgs, lib, ylib, ... } @ args: {
  home.stateVersion = "23.11";
  programs.home-manager.enable = true;

  home.username = settings.user.username;
  home.homeDirectory = "/home/${settings.user.username}";
}
