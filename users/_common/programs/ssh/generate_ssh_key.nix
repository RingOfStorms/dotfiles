{ settings, pkgs, ... }:
''
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
''
