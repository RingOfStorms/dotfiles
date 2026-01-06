{
  osConfig,
  lib,
  ...
}:
let
  inherit (osConfig) age;
  hasSecret =
    secret:
    let
      secrets = age.secrets or { };
    in
    secrets ? ${secret} && secrets.${secret} != null;
in
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
      "github.com" = lib.mkIf (hasSecret "nix2github") {
        identityFile = age.secrets.nix2github.path;
      };
      "bitbucket.org" = lib.mkIf (hasSecret "nix2bitbucket") {
        identityFile = age.secrets.nix2bitbucket.path;
      };
      "git.joshuabell.xyz" = {
        identityFile = lib.mkIf (hasSecret "nix2gitforgejo") age.secrets.nix2gitforgejo.path;
        user = "git";
      };
      # PERSONAL DEVICES
      "lio" = {
        identityFile = lib.mkIf (hasSecret "nix2lio") age.secrets.nix2lio.path;
        user = "josh";
      };
      "lio_" = {
        identityFile = lib.mkIf (hasSecret "nix2lio") age.secrets.nix2lio.path;
        hostname = "10.12.14.116";
        user = "josh";
      };
      "oren" = {
        identityFile = lib.mkIf (hasSecret "nix2oren") age.secrets.nix2oren.path;
        user = "josh";
      };
      "juni" = {
        identityFile = lib.mkIf (hasSecret "nix2nix") age.secrets.nix2nix.path;
        user = "josh";
      };
      "gp3" = {
        identityFile = lib.mkIf (hasSecret "nix2gpdPocket3") age.secrets.nix2gpdPocket3.path;
        user = "josh";
      };
      "t" = {
        identityFile = lib.mkIf (hasSecret "nix2t") age.secrets.nix2t.path;
        user = "joshua.bell";
        localForwards = [
          {
            bind.port = 3002;
            host.port = 3002;
            host.address = "localhost";
          }
        ];
        setEnv = {
          TERM = "vt100";
        };
      };
      "t_" = {
        identityFile = lib.mkIf (hasSecret "nix2t") age.secrets.nix2t.path;
        hostname = "10.12.14.181";
        user = "joshua.bell";
        localForwards = [
          {
            bind.port = 3002;
            host.port = 3002;
            host.address = "localhost";
          }
        ];
        setEnv = {
          TERM = "vt100";
        };
      };
      # HOME SERVERS
      "h001" = {
        identityFile = lib.mkIf (hasSecret "nix2h001") age.secrets.nix2h001.path;
        user = "luser";
      };
      "h001_" = {
        identityFile = lib.mkIf (hasSecret "nix2h001") age.secrets.nix2h001.path;
        hostname = "10.12.14.10";
        user = "luser";
      };
      "h002" = {
        identityFile = lib.mkIf (hasSecret "nix2nix") age.secrets.nix2nix.path;
        user = "luser";
      };
      "h002_" = {
        identityFile = lib.mkIf (hasSecret "nix2nix") age.secrets.nix2nix.path;
        hostname = "10.12.14.183";
        user = "luser";
      };
      "h003" = {
        identityFile = lib.mkIf (hasSecret "nix2h003") age.secrets.nix2h003.path;
        hostname = "10.12.14.1";
        user = "luser";
      };
      "h003_" = {
        identityFile = lib.mkIf (hasSecret "nix2h003") age.secrets.nix2h003.path;
        user = "luser";
      };
      # LINODE SERVERS
      "l001" = {
        identityFile = lib.mkIf (hasSecret "nix2linode") age.secrets.nix2linode.path;
        hostname = "172.236.111.33"; # Not on the tailscale network it is the primary host
        user = "root";
      };
      "l002_" = {
        identityFile = lib.mkIf (hasSecret "nix2linode") age.secrets.nix2linode.path;
        hostname = "172.234.26.141";
        user = "root";
      };
      "l002" = {
        identityFile = lib.mkIf (hasSecret "nix2linode") age.secrets.nix2linode.path;
        user = "root";
      };
      # ORACLE SERVERS
      "o001" = {
        identityFile = lib.mkIf (hasSecret "nix2oracle") age.secrets.nix2oracle.path;
        user = "root";
      };
      "o001_" = {
        identityFile = lib.mkIf (hasSecret "nix2oracle") age.secrets.nix2oracle.path;
        hostname = "64.181.210.7";
        user = "root";
      };
    };
  };
}
