{ age, ... }:
{
  # TODO can I put all IP's in the flake.nix top level settings and pull them in here instead?
  programs.ssh = {
    enable = true;
    matchBlocks = {
      # EXTERNAL
      "github.com" = {
        identityFile = age.secrets.nix2github.path;
      };
      "bitbucket.org" = {
        identityFile = age.secrets.nix2bitbucket.path;
      };
      # PERSONAL DEVICES
      "joe" = {
        identityFile = age.secrets.nix2joe.path;
        hostname = "10.20.40.102";
        user = "josh";
      };
      "gpdPocket3" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.20.40.103";
        user = "josh";
      };
      "t" = {
        identityFile = age.secrets.nix2t.path;
        hostname = "10.20.40.180";
        user = "joshua.bell";
        localForwards = [
          {
            bind.port = 3000;
            host.port = 3000;
            host.address = "localhost";
          }
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
      "mbptv" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.20.40.109";
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
        hostname = "10.20.40.124";
        user = "TODO";
      };
      "ipad1" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.20.40.125";
        user = "TODO";
      };
      "tab1" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.20.40.120";
        user = "TODO";
      };
      "pixel6" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.20.40.126"; # TODO ON BOARD
        user = "TODO";
      };
      # HOME SERVERS
      "h001" = {
        identityFile = age.secrets.nix2h001.path;
        hostname = "10.20.40.190";
        user = "root";
      };
      "h001_" = {
        identityFile = age.secrets.nix2h001.path;
        hostname = "10.12.14.2";
        user = "root";
      };
      "h002" = {
        identityFile = age.secrets.nix2h002.path;
        hostname = "10.20.40.191";
        user = "luser";
      };
      # LINODE SERVERS
      "l001" = {
        identityFile = age.secrets.nix2l001.path;
        hostname = "172.105.22.34"; # TODO  REMOVE - OFF BOARD
        user = "root";
      };
      "l002_" = {
        identityFile = age.secrets.nix2l002.path;
        hostname = "172.232.4.54";
        user = "luser";
      };
      "l002" = {
        identityFile = age.secrets.nix2l002.path;
        hostname = "10.20.40.1";
        user = "luser";
      };
    };
  };
}
