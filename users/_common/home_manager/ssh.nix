{ age, ... }:
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "github.com" = {
        identityFile = age.secrets.nix2github.path;
      };
      "bitbucket.org" = {
        identityFile = age.secrets.nix2bitbucket.path;
      };
      "h001" = {
        identityFile = age.secrets.nix2h001.path;
        # TODO come back to these 10.12.14.## addrs and change them to intranet IP's instead of local network.
        # LOCAL HOME NETWORK ONLY
        hostname = "10.12.14.2";
        user = "root";
      };
      "h002" = {
        identityFile = age.secrets.nix2h002.path;
        hostname = "10.20.40.12";
        user = "luser";
      };
      "joe" = {
        identityFile = age.secrets.nix2joe.path;
        hostname = "10.20.40.2";
        user = "josh";
      };
      "gpdPocket3" = {
        identityFile = age.secrets.nix2gpdPocket3.path;
        hostname = "10.20.40.22"; # TODO onboard ot nebula network
        user = "josh";
      };
      "t" = {
        identityFile = age.secrets.nix2t.path;
        hostname = "10.20.40.4"; # TODO get these from flake.nix hosts?
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
      "l001" = {
        identityFile = age.secrets.nix2l001.path;
        hostname = "172.105.22.34";
        user = "root";
      };
      "l002" = {
        identityFile = age.secrets.nix2l002.path;
        hostname = "172.233.221.107";
        user = "root";
      };
    };
  };
}
