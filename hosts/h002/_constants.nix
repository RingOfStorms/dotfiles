# Service constants for h002 (NAS - bcachefs)
# Single source of truth for ports, UIDs/GIDs, data paths.
{
  host = {
    name = "h002";
    overlayIp = "100.64.0.3";
    lanIp = "10.12.14.183";
    primaryUser = "luser";
    stateVersion = "25.11";
  };

  services = {
    nfs = {
      nfsPort = 2049;
      rpcbindPort = 111;
      mountdPort = 892;
      lockdPort = 32803;
      statdPort = 662;
      exportRoot = "/data";
    };

    pinchflat = {
      uid = 186;
      gid = 186;
      mediaDir = "/data/pinchflat/media";
    };

    nixarr = {
      mediaDir = "/data/nixarr/media";
    };
  };

  secrets = {
    nix2nix_2026-03-15 = {
      owner = "luser";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks = {
          "lio".identityFile = "$SECRET_PATH";
          "lio_".identityFile = "$SECRET_PATH";
          "oren".identityFile = "$SECRET_PATH";
          "juni".identityFile = "$SECRET_PATH";
          "gp3".identityFile = "$SECRET_PATH";
          "t".identityFile = "$SECRET_PATH";
          "t_".identityFile = "$SECRET_PATH";
          "h001".identityFile = "$SECRET_PATH";
          "h001_".identityFile = "$SECRET_PATH";
          "h002".identityFile = "$SECRET_PATH";
          "h002_".identityFile = "$SECRET_PATH";
          "h003".identityFile = "$SECRET_PATH";
          "h003_".identityFile = "$SECRET_PATH";
          "l001".identityFile = "$SECRET_PATH";
          "l002".identityFile = "$SECRET_PATH";
          "l002_".identityFile = "$SECRET_PATH";
          "o001".identityFile = "$SECRET_PATH";
          "o001_".identityFile = "$SECRET_PATH";
        };
      };
    };

    nix2github_2026-03-15 = {
      owner = "luser";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
      };
    };

    nix2gitforgejo_2026-03-15 = {
      owner = "luser";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks."git.joshuabell.xyz".identityFile = "$SECRET_PATH";
      };
    };

    headscale_auth_2026-03-15 = {
      softDepend = [ "tailscaled" ];
      configChanges = {
        services.tailscale.authKeyFile = "$SECRET_PATH";
      };
    };

    github_read_token_2026-03-15 = {
      configChanges = {
        nix.extraOptions = "!include $SECRET_PATH";
      };
    };
  };
}
