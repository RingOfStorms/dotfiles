{ settings, ringofstorms-nvim, ... }:
{
  environment.systemPackages = [
    ringofstorms-nvim.packages.${settings.system.system}.neovim
  ];
}

