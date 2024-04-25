{ settings, pkgs, ... }:
let
  sshScript = pkgs.writeScript "ssh-key-generation" ''
    #!${pkgs.stdenv.shell}
    if [ ! -f /home/${settings.user.username}/.ssh/id_ed25519]; then
      if [ -v DRY_RUN ]; then
        echo "DRY_RUN is set. Would generate SSH key for ${settings.user.username}."
      else
        echo "Generating SSH key for ${settings.user.username}."
        mkdir -p /home/${settings.user.username}/.ssh
        chmod 700 /home/${settings.user.username}/.ssh
        /run/current-system/sw/bin/ssh-keygen -t ed25519 -f /home/${settings.user.username}/.ssh/id_ed25519-N ""
      fi
    else
      echo "SSH key already exists for ${settings.user.username}."
    fi
  '';
in
{
  # Ensure SSH key pair generation for non-root users
  systemd.services.generate_ssh_key = {
    description = "Generate SSH key pair for ${settings.user.username}";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "${settings.user.username}";
      Type = "oneshot";
      ExecStart = sshScript;
    };
  };
}
