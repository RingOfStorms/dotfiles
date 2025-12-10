{
  inputs = {
    opencode.url = "github:sst/opencode";
  };

  outputs =
    { opencode, ... }:
    {
      nixosModules = {
        default =
          {
            pkgs,
            ...
          }:
          {
            environment.systemPackages = [
              opencode.packages.${pkgs.system}.default
            ];

            environment.shellAliases = {
              "oc" = "all_proxy='' http_proxy='' https_proxy='' opencode";
              "occ" = "oc -c";
            };
          };
      };
    };
}
