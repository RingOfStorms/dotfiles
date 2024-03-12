{ lib, settings, age, pkgs, ... } @ args:
{
  # We always want a standard ssh key-pair used for secret management, create it if not there.
  home.activation.generateSshKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f $HOME/.ssh/id_ed25519 ]; then
      if [ -v DRY_RUN ]; then
        echo "DRY_RUN is set. Would generate SSH key for ${settings.user.username}."
      else
        echo "Generating SSH key for ${settings.user.username}."
        mkdir -p $HOME/.ssh
        chmod 700 $HOME/.ssh
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f $HOME/.ssh/id_ed25519 -N ""
      fi
    else
      echo "SSH key already exists for ${settings.user.username}."
    fi
  '';

  programs.ssh = {
    enable = true;
    matchBlocks = {
      "github.com" = {
        identityFile = age.secrets.nix2github.path;
      };
    };
  };
}

