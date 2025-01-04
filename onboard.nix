{ pkgs, ... }:
{
  networking.hostName = "%%HOSTNAME%%";
  networking.networkmanager.enable = true;
  
  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
  
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  
  environment.systemPackages = with pkgs; [
    vim
    curl
    git
    sudo
  ];
  
  users.users.%%USERNAME%% = {
    initialPassword = "password1";
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "input" ];
  };
  
  # Ensure SSH key pair generation for non-root users
  systemd.services.generate_ssh_key = {
    description = "Generate SSH key pair for %%USERNAME%%";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "%%USERNAME%%";
      Type = "oneshot";
    };
    script = ''
      #!/run/current-system/sw/bin/bash
      if [ ! -f /home/%%USERNAME%%/.ssh/id_ed25519 ]; then
        if [ -v DRY_RUN ]; then
          echo "DRY_RUN is set. Would generate SSH key for %%USERNAME%%."
        else
          echo "Generating SSH key for %%USERNAME%%."
          mkdir -p /home/%%USERNAME%%/.ssh
          chmod 700 /home/%%USERNAME%%/.ssh
          /run/current-system/sw/bin/ssh-keygen -t ed25519 -f /home/%%USERNAME%%/.ssh/id_ed25519 -N ""
        fi
      else
        echo "SSH key already exists for %%USERNAME%%."
      fi
    '';
  };
}
