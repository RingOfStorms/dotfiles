{ settings, pkgs, lib, ylib, ... } @ args: {
  home.stateVersion = "23.11";
  programs.home-manager.enable = true;

  home.username = settings.user.username;
  home.homeDirectory = "/home/${settings.user.username}";

  # We always want a standard ssh key-pair used for secret management, create it if not there.
  home.activation.generateSshKey = lib.hm.dag.entryAfter [ "writeBoundary" ] (import ./generate_ssh_key.nix args);

  imports = ylib.umport { paths = [ ./programs ]; recursive = true; };
}
