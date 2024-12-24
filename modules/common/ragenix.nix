{
  config,
  ragenix,
  pkgs,
  ...
}:
# TODO auto import secret files here
# secretsFile = (settings.secretsDir + /secrets.nix);
{
  environment.systemPackages = [
    ragenix.packages.${pkgs.system}.default
    pkgs.rage
  ];

  age = {
    secrets =
      # builtins.mapAttrs
      #   (name: _value: lib.nameValuePair (lib.removeSuffix ".age" name) {
      #     file = (settings.secretsDir + "/${name}");
      #     owner = lib.mkDefault config.mods.common.primaryUser;
      #   })
      #   (import secretsFile);
      {
        nix2github = {
          file = ./secrets/nix2github.age;
          owner = config.mods.common.primaryUser;
        };
        nix2bitbucket = {
          file = ./secrets/nix2bitbucket.age;
          owner = config.mods.common.primaryUser;
        };
        nix2gitjosh = {
          file = ./secrets/nix2gitjosh.age;
          owner = config.mods.common.primaryUser;
        };
        nix2h001 = {
          file = ./secrets/nix2h001.age;
          owner = config.mods.common.primaryUser;
        };
        nix2h002 = {
          file = ./secrets/nix2h002.age;
          owner = config.mods.common.primaryUser;
        };
        nix2joe = {
          file = ./secrets/nix2joe.age;
          owner = config.mods.common.primaryUser;
        };
        nix2gpdPocket3 = {
          file = ./secrets/nix2gpdPocket3.age;
          owner = config.mods.common.primaryUser;
        };
        nix2t = {
          file = ./secrets/nix2t.age;
          owner = config.mods.common.primaryUser;
        };
        nix2l001 = {
          file = ./secrets/nix2l001.age;
          owner = config.mods.common.primaryUser;
        };
        nix2l002 = {
          file = ./secrets/nix2l002.age;
          owner = config.mods.common.primaryUser;
        };
        nix2lio = {
          file = ./secrets/nix2lio.age;
          owner = config.mods.common.primaryUser;
        };
        nix2oren = {
          file = ./secrets/nix2oren.age;
          owner = config.mods.common.primaryUser;
        };
        github_read_token = {
          file = ./secrets/github_read_token.age;
          owner = config.mods.common.primaryUser;
        };
      };
  };
}
