# TODO check out the by host way this person does: https://github.com/hlissner/dotfiles/blob/089f1a9da9018df9e5fc200c2d7bef70f4546026/modules/agenix.nix
{
  settings,
  lib,
  pkgs,
  ragenix,
  ...
}:
# TODO auto import secret files here
# secretsFile = (settings.secretsDir + /secrets.nix);
{
  imports = [ ragenix.nixosModules.age ];
  environment.systemPackages = [
    ragenix.packages.${settings.system.system}.default
    pkgs.rage
  ];

  age = {
    secrets =
      # builtins.mapAttrs
      #   (name: _value: lib.nameValuePair (lib.removeSuffix ".age" name) {
      #     file = (settings.secretsDir + "/${name}");
      #     owner = lib.mkDefault settings.user.username;
      #   })
      #   (import secretsFile);
      {
        nix2github = {
          file = /${settings.secretsDir}/nix2github.age;
          owner = settings.user.username;
        };
        nix2bitbucket = {
          file = /${settings.secretsDir}/nix2bitbucket.age;
          owner = settings.user.username;
        };
        nix2gitjosh = {
          file = /${settings.secretsDir}/nix2gitjosh.age;
          owner = settings.user.username;
        };
        nix2h001 = {
          file = /${settings.secretsDir}/nix2h001.age;
          owner = settings.user.username;
        };
        nix2h002 = {
          file = /${settings.secretsDir}/nix2h002.age;
          owner = settings.user.username;
        };
        nix2joe = {
          file = /${settings.secretsDir}/nix2joe.age;
          owner = settings.user.username;
        };
        nix2gpdPocket3 = {
          file = /${settings.secretsDir}/nix2gpdPocket3.age;
          owner = settings.user.username;
        };
        nix2t = {
          file = /${settings.secretsDir}/nix2t.age;
          owner = settings.user.username;
        };
        nix2l001 = {
          file = /${settings.secretsDir}/nix2l001.age;
          owner = settings.user.username;
        };
        nix2l002 = {
          file = /${settings.secretsDir}/nix2l002.age;
          owner = settings.user.username;
        };
        nix2lio = {
          file = /${settings.secretsDir}/nix2lio.age;
          owner = settings.user.username;
        };
        nix2oren = {
          file = /${settings.secretsDir}/nix2oren.age;
          owner = settings.user.username;
        };
        github_read_token = {
          file = /${settings.secretsDir}/github_read_token.age;
          owner = settings.user.username;
        };
      };
  };
}
