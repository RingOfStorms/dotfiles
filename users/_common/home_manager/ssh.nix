{ age, ... }:
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "github.com" = {
        identityFile = age.secrets.nix2github.path;
      };
      "bitbucket.org" = {
        identityFile = age.secrets.nix2bitbucket.path;
      };
    };
  };
}

