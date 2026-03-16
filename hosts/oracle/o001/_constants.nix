# Service constants for o001 (Oracle Cloud - Public Gateway)
# Single source of truth for ports, UIDs/GIDs, data paths.
{
  host = {
    name = "o001";
    overlayIp = "100.64.0.11";
    primaryUser = "root";
    stateVersion = "23.11";
    domain = "joshuabell.xyz";
    acmeEmail = "admin@joshuabell.xyz";
  };

  # The Tailscale IP of h001, used by nginx to proxy most services
  upstreamHost = "100.64.0.13";

  services = {
    vaultwarden = {
      port = 8222;
      uid = 114;
      gid = 114;
      dataDir = "/var/lib/vaultwarden";
      domain = "vault.joshuabell.xyz";
    };

    atuin = {
      port = 8888;
      domain = "atuin.joshuabell.xyz";
    };

    rustdesk = {
      ports = {
        signal = 21115;
        relay = 21116;
        relayHbbs = 21117;
        tcp4 = 21118;
        tcp5 = 21119;
      };
    };

    # Test container
    wasabi = {
      hostAddress = "192.168.100.2";
      containerIp = "192.168.100.11";
    };
  };

  secrets = {
    nix2nix_2026-03-15 = {
      owner = "root";
      group = "root";
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
      owner = "root";
      group = "root";
      hmChanges = {
        programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
      };
    };

    nix2gitforgejo_2026-03-15 = {
      owner = "root";
      group = "root";
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

    litellm_public_api_key_2026-03-15 = { };

    vaultwarden_env_2026-03-15 = { };
  };
}
