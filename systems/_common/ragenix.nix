# TODO check out the by host way this person does: https://github.com/hlissner/dotfiles/blob/089f1a9da9018df9e5fc200c2d7bef70f4546026/modules/agenix.nix
{ settings, lib, inputs, ... }:
let
  secretsDir = "${settings.secretsDir}";
  secretsFile = "${secretsDir}/secrets.nix";
in
{
  # imports = [ inputs.ragenix.nixosModules.age ];
  environment.systemPackages = [ inputs.ragenix.defaultPackage.${settings.system.architecture} ];

  # age = {
  #   secrets =
  #     if pathExists secretsFile
  #     then
  #       mapAttrs'
  #         (n: _: nameValuePair (removeSuffix ".age" n) {
  #           file = "${secretsDir}/${n}";
  #           owner = mkDefault settings.user.username; # TODO and root? or does that matter...
  #         })
  #         (import secretsFile)
  #     else { };
  # };
}
