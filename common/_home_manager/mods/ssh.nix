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
    extraConfig = ''
      Host *
        SetEnv TERM=xterm-256color
    '';
    matchBlocks = {
      # EXTERNAL
      "github.com" = lib.mkIf (hasSecret "nix2github") {
        identityFile = age.secrets.nix2github.path;
      };
      "bitbucket.org" = lib.mkIf (hasSecret "nix2bitbucket") {
        identityFile = age.secrets.nix2bitbucket.path;
      };
      # "git.joshuabell.xyz" =  lib.mkIf (hasSecret "nix2gitjosh") { # TODO remove old
      #   identityFile = age.secrets.nix2gitjosh.path;
      #   user = "git";
      # };
      "git.joshuabell.xyz" = lib.mkIf (hasSecret "nix2gitforgejo") {
        identityFile = age.secrets.nix2gitforgejo.path;
        user = "git";
      };
      # PERSONAL DEVICES
      "lio" = lib.mkIf (hasSecret "nix2lio") {
        identityFile = age.secrets.nix2lio.path;
        user = "josh";
      };
      "lio_" = lib.mkIf (hasSecret "nix2lio") {
        identityFile = age.secrets.nix2lio.path;
        hostname = "10.12.14.116";
        user = "josh";
      };
      "oren" = lib.mkIf (hasSecret "nix2oren") {
        identityFile = age.secrets.nix2oren.path;
        user = "josh";
      };
      "joe" = lib.mkIf (hasSecret "nix2joe") {
        identityFile = age.secrets.nix2joe.path;
        user = "ringo";
      };
      "gp3" = lib.mkIf (hasSecret "nix2gpdPocket3") {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "josh";
      };
      "t" = lib.mkIf (hasSecret "nix2t") {
        identityFile = age.secrets.nix2t.path;
        user = "joshua.bell";
        localForwards = [
          # {
          #   bind.port = 3000;
          #   host.port = 3000;
          #   host.address = "localhost";
          # }
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
      "t_" = lib.mkIf (hasSecret "nix2t") {
        identityFile = age.secrets.nix2t.path;
        hostname = "10.12.14.103";
        user = "joshua.bell";
        setEnv = {
          TERM = "vt100";
        };
      };
      "mbptv" = lib.mkIf (hasSecret "nix2gpdPocket3") {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "waka";
        setEnv = {
          TERM = "vt100";
        };
      };
      "mbptv_" = lib.mkIf (hasSecret "nix2gpdPocket3") {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.12.14.30";
        user = "waka";
        setEnv = {
          TERM = "vt100";
        };
      };
      "nothing1" = lib.mkIf (hasSecret "nix2gpdPocket3") {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "TODO";
      };
      "tab1" = lib.mkIf (hasSecret "nix2gpdPocket3") {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "TODO";
      };
      "pixel6" = lib.mkIf (hasSecret "nix2gpdPocket3") {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "TODO";
      };
      # HOME SERVERS
      "h001" = lib.mkIf (hasSecret "nix2h001") {
        identityFile = age.secrets.nix2h001.path;
        user = "luser";
      };
      "h001_" = lib.mkIf (hasSecret "nix2h001") {
        identityFile = age.secrets.nix2h001.path;
        hostname = "10.12.14.10";
        user = "luser";
      };
      "h002" = lib.mkIf (hasSecret "nix2h002") {
        identityFile = age.secrets.nix2h002.path;
        user = "luser";
      };
      "h003" = lib.mkIf (hasSecret "nix2h003") {
        identityFile = age.secrets.nix2h003.path;
        user = "luser";
      };
      # LINODE SERVERS
      "l001" = lib.mkIf (hasSecret "nix2linode") {
        identityFile = age.secrets.nix2linode.path;
        hostname = "172.236.111.33"; # Not on the tailscale network it is the primary host
        user = "root";
      };
      "l002_" = lib.mkIf (hasSecret "nix2linode") {
        identityFile = age.secrets.nix2linode.path;
        hostname = "172.234.26.141";
        user = "root";
      };
      "l002" = lib.mkIf (hasSecret "nix2linode") {
        identityFile = age.secrets.nix2linode.path;
        user = "root";
      };
      # ORACLE SERVERS
      "o001" = lib.mkIf (hasSecret "nix2oracle") {
        identityFile = age.secrets.nix2oracle.path;
        user = "root";
      };
      "o001_" = lib.mkIf (hasSecret "nix2oracle") {
        identityFile = age.secrets.nix2oracle.path;
        hostname = "64.181.210.7";
        user = "root";
      };
    };
  };
}
