# TODO check out the by host way this person does: https://github.com/hlissner/dotfiles/blob/089f1a9da9018df9e5fc200c2d7bef70f4546026/modules/agenix.nix
{ settings, lib, ragenix, ... }:
let
  # secretsDir = "${settings.secretsDir}";
  # secretsFile = "${secretsDir}/secrets.nix";
in
{
  imports = [ ragenix.nixosModules.age ];
  environment.systemPackages = [ ragenix.packages.${settings.system.architecture}.default ];

  age = {
    secrets =
      # if builtins.pathExists secretsFile
      # then
      #   builtins.mapAttrs'
      #     (n: _: lib.nameValuePair (lib.removeSuffix ".age" n) {
      #       file = "${secretsDir}/${n}";
      #       owner = lib.mkDefault settings.user.username; # TODO and root? or does that matter...
      #     })
      #     (import secretsFile)
      # else { };
      {
        test1 = {
          file = /${settings.secretsDir}/test1.age;
          owner = settings.user.username;
        };
      };
  };
}
