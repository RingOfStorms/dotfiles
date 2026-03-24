{ fleet ? null, ... }:
let
  # When fleet data is available (passed via extraSpecialArgs from mkHost),
  # generate matchBlocks from the fleet registry. Otherwise, fall back to
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
    matchBlocks = {
      "*" = {
        forwardAgent = false;
        addKeysToAgent = "no";
        compression = false;
        serverAliveInterval = 0;
        serverAliveCountMax = 3;
        hashKnownHosts = false;
        userKnownHostsFile = "~/.ssh/known_hosts";
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
        extraOptions = {
          StrictHostKeyChecking = "accept-new";
        };
        setEnv = {
          TERM = "xterm-256color";
        };
      };

      # EXTERNAL (not in fleet registry)
      "github.com" = { };
      "git.joshuabell.xyz" = {
        user = "git";
      };
    } // fleetBlocks;
  };
}
