{
  inputs = {
    ringofstorms-stormd.url = "git+ssh://git.joshuabell.xyz:3032/stormd";
    # Local path usage for testing changes locally
    # ringofstorms-nvim.url = "path:/home/josh/projects/stormd";
  };

  outputs =
    {
      ringofstorms-stormd,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          with lib;
          {
            options.mods.ros-stormd = {
              debug = mkOption {
                type = types.bool;
                default = false;
                description = lib.mdDoc "Whether to enable debug logging for stormd daemon.";
              };
            };
            imports = [ ringofstorms-stormd.nixosModules.default ];
            config = {
              services.stormd = {
                enable = true;
                nebulaPackage = pkgs.nebula;
                extraOptions = mkIf config.mods.ros-stormd.debug [ "-v" ];
              };
            };
          };
      };
    };
}
