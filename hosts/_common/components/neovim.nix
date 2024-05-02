{ pkgs, settings, ringofstorms-nvim, ... }:
{
  environment.systemPackages = with pkgs; [
    ringofstorms-nvim.packages.${settings.system.system}.neovim
  ];
}

