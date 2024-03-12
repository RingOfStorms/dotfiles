{ config, lib, pkgs, settings, ... } @ args:
{
  users.users.root = {
    initialPassword = "password1";
  };

  system.activationScripts.sshConfig = {
    text = ''
      mkdir -p /root/.ssh
      ln -snf ${config.age.secrets.nix2github.path} /root/.ssh/nix2github
      ln -snf /home/${settings.user.username}/.ssh/config /root/.ssh/config
    '';
  };
}

