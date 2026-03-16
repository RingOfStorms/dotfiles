# Service constants for lio (System76 Thelio - Primary Workstation)
# Single source of truth for ports, data paths, and service configuration.
{
  host = {
    name = "lio";
    overlayIp = "100.64.0.1";
    primaryUser = "josh";
  };

  services = {
    nixServe = {
      port = 5000;
      secretKeyFile = "/var/lib/nix-serve/cache-priv-key.pem";
    };
  };

  secrets = {
    nix2nix_2026-03-15 = {
      owner = "josh";
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
      owner = "josh";
      group = "users";
      hmChanges = {
        programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
      };
    };

    nix2gitforgejo_2026-03-15 = {
      owner = "josh";
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
