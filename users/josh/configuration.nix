{ config, lib, ylib, pkgs, settings, ... } @ args:
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

  home-manager.users.${settings.user.username} = {
    imports =
      # Common settings all users share
      [ (settings.usersDir + "/_common/home.nix") ]
      # Programs
      ++ ylib.umport {
        paths = [ ./programs ];
        recursive = true;
      }
      # Programs by host
      ++ ylib.umport {
        paths = [ ./by_hosts/${settings.system.hostname} ];
        recursive = true;
      };
  };
} 

