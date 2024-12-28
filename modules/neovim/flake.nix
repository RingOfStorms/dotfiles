{
  inputs = {
    ringofstorms-nvim.url = "git+https://git.joshuabell.xyz/nvim";
  };

  outputs =
    {
      ringofstorms-nvim,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            pkgs,
            ...
          }:
          {
            environment.systemPackages = [
              ringofstorms-nvim.packages.${pkgs.system}.neovim
            ];
          };
      };
    };
}
