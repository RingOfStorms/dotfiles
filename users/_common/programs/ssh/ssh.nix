{ lib, ... } @ args:
{
  # We always want a standard ssh key-pair used for secret management, create it if not there.
  home.activation.generateSshKey = lib.hm.dag.entryAfter [ "writeBoundary" ] (import ./generate_ssh_key.nix args);

  programs.ssh = {
    enable = true;
    matchBlocks = {
      github = {
        hostname = "github.com";
        # TODO lEFT OFF HERE TRYING TO GET THIS TO WORK
        # identityFile = age.secrets.test1.file;
      };
    };
  };
}

