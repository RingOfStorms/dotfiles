{ pkgs, settings, ... }: {
  home.stateVersion = "23.11";

  home.username = settings.user.username;
  home.homeDirectory = "/home/${settings.user.username}";

  programs.home-manager.enable = true;
}
