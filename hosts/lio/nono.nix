{ pkgs, inputs, ... }:
{
  environment.systemPackages = [ inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.nono ];
}
