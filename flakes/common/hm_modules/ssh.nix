{ fleet ? null, ... }:
let
  # When fleet data is available (passed via extraSpecialArgs from mkHost),
  # generate settings blocks from the fleet registry. Otherwise, fall back to
  # a minimal static config.
  fleetBlocks =
    if fleet != null
    then fleet.mkSshMatchBlocks
    else {};
in
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    includes = [ "~/.ssh/extra_config" ];
    # home-manager 26.05 replaced `matchBlocks` (camelCase option names) with
    # `settings` (freeform attrset of upstream OpenSSH directive names).
    settings = {
      "*" = {
        ForwardAgent = false;
        AddKeysToAgent = "no";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
        StrictHostKeyChecking = "accept-new";
        SetEnv = {
          TERM = "xterm-256color";
        };
      };

      # EXTERNAL (not in fleet registry)
      "github.com" = { };
      "git.joshuabell.xyz" = {
        User = "git";
      };
    } // fleetBlocks;
  };
}
