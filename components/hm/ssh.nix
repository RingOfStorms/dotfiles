{ nixConfig, ... }:
let
  inherit (nixConfig) age;
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
      "github.com" = {
        identityFile = age.secrets.nix2github.path;
      };
      "bitbucket.org" = {
        identityFile = age.secrets.nix2bitbucket.path;
      };
      "git.joshuabell.xyz" = {
        identityFile = age.secrets.nix2gitjosh.path;
        user = "git";
      };
      # PERSONAL DEVICES
      "lio" = {
        identityFile = age.secrets.nix2lio.path;
        user = "josh";
      };
      "lio_" = {
        identityFile = age.secrets.nix2lio.path;
        hostname = "10.12.14.116";
        user = "josh";
      };
      "oren" = {
        identityFile = age.secrets.nix2oren.path;
        user = "josh";
      };
      "joe" = {
        identityFile = age.secrets.nix2joe.path;
        user = "josh";
      };
      "gp3" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "josh";
      };
      "t" = {
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
      "t_" = {
        identityFile = age.secrets.nix2t.path;
        hostname = "10.12.14.103";
        user = "joshua.bell";
        setEnv = {
          TERM = "vt100";
        };
      };
      "mbptv" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "waka";
        setEnv = {
          TERM = "vt100";
        };
      };
      "mbptv_" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.12.14.101";
        user = "waka";
        setEnv = {
          TERM = "vt100";
        };
      };
      "nothing1" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "TODO";
      };
      "tab1" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "TODO";
      };
      "pixel6" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        user = "TODO";
      };
      # HOME SERVERS
      "h001" = {
        identityFile = age.secrets.nix2h001.path;
        user = "root";
      };
      "h001_" = {
        identityFile = age.secrets.nix2h001.path;
        hostname = "10.12.14.2";
        user = "root";
      };
      "h002" = {
        identityFile = age.secrets.nix2h002.path;
        user = "luser";
      };
      # LINODE SERVERS
      "l001" = {
        identityFile = age.secrets.nix2linode.path;
        hostname = "172.236.111.33";
        user = "root";
      };
      "l002_" = {
        identityFile = age.secrets.nix2linode.path;
        hostname = "172.234.26.141";
        user = "root";
      };
      "l002" = {
        identityFile = age.secrets.nix2linode.path;
        user = "root";
      };
    };
  };
}
