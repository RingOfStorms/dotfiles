{ ... }:
{
  # TODO can I put all IP's in the flake.nix top level settings and pull them in here instead?
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

      # EXTERNAL
      "github.com" = { };
      "git.joshuabell.xyz" = {
        user = "git";
      };
      # PERSONAL DEVICES
      "lio" = {
        user = "josh";
      };
      "lio_" = {
        hostname = "10.12.14.116";
        user = "josh";
      };
      "oren" = {
        user = "josh";
      };
      "juni" = {
        user = "josh";
      };
      "gp3" = {
        user = "josh";
      };
      "joe" = {
        user = "josh";
      };
      "t" = {
        user = "joshua.bell";
        setEnv = {
          TERM = "vt100";
        };
      };
      "t_" = {
        hostname = "10.12.14.181";
        user = "joshua.bell";
        setEnv = {
          TERM = "vt100";
        };
      };
      # HOME SERVERS
      "h001" = {
        user = "luser";
      };
      "h001_" = {
        hostname = "10.12.14.10";
        user = "luser";
      };
      "h002" = {
        user = "luser";
      };
      "h002_" = {
        hostname = "10.12.14.183";
        user = "luser";
      };
      "h003" = {
        hostname = "10.12.14.1";
        user = "luser";
      };
      "h003_" = {
        user = "luser";
      };
      # LINODE SERVERS
      "l001" = {
        hostname = "172.236.111.33"; # Not on the tailscale network it is the primary host
        user = "root";
      };
      "l002_" = {
        hostname = "172.234.26.141";
        user = "root";
      };
      "l002" = {
        user = "root";
      };
      # ORACLE SERVERS
      "o001" = {
        user = "root";
      };
      "o001_" = {
        hostname = "64.181.210.7";
        user = "root";
      };
    };
  };
}
