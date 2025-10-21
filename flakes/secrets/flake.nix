{
  inputs = {
    ragenix.url = "github:yaxitech/ragenix";
  };

  outputs =
    {
      ragenix,
      ...
    }:
    {
      nixosModules = {
        default =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            imports = [
              ragenix.nixosModules.age
              ./secrets
            ];
            config = {
              _module.args = {
                inherit ragenix;
              };
            };
          };
      };
    };
}
