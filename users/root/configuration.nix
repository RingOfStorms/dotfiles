{
  config,
  lib,
  pkgs,
  settings,
  ...
}@args:
{
  users.users.root = {
    initialPassword = "password1";
  };

  system.activationScripts.sshConfig = {
    # TODO revisit this, this is stupid and ugly what am I doing here...
    # this is just making it so that the root user can fetch from github. I don't think I need this anymore...
    text = ''
      mkdir -p /root/.ssh
      ln -snf ${config.age.secrets.nix2github.path} /root/.ssh/nix2github
      ln -snf /home/${settings.user.username}/.ssh/config /root/.ssh/config
    '';
  };
}
