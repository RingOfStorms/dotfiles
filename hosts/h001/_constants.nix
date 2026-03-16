# Service constants for h001 (Service Host)
# Single source of truth for ports, UIDs/GIDs, data paths, container IPs, and domains.
# Import this file in flake.nix and pass to service modules via specialArgs or let bindings.
{
  # Host-level
  host = {
    name = "h001";
    overlayIp = "100.64.0.13";
    lanIp = "10.12.14.10";
    primaryUser = "luser";
    stateVersion = "24.11";
    domain = "joshuabell.xyz";
    acmeEmail = "admin@joshuabell.xyz";
  };

  # Container network (shared host address for all NixOS containers)
  containerNetwork = {
    hostAddress = "10.0.0.1";
    hostAddress6 = "fc00::1";
  };

  services = {
    forgejo = {
      port = 3000;
      sshPort = 3032;
      uid = 115;
      gid = 115;
      dataDir = "/var/lib/forgejo";
      containerIp = "10.0.0.2";
      containerIp6 = "fc00::2";
      domain = "git.joshuabell.xyz";
    };

    zitadel = {
      port = 8080;
      dataDir = "/var/lib/zitadel";
      containerIp = "10.0.0.3";
      containerIp6 = "fc00::3";
      domain = "sso.joshuabell.xyz";
    };

    immich = {
      port = 2283;
      uid = 916;
      gid = 916;
      dataDir = "/drives/wd10/immich";
      varLibDir = "/var/lib/immich";
      containerIp = "10.0.0.4";
      containerIp6 = "fc00::4";
      domain = "photos.joshuabell.xyz";
    };

    dawarich = {
      port = 3001;
      uid = 977;
      gid = 977;
      redisUid = 976;
      redisGid = 976;
      dataDir = "/drives/wd10/dawarich";
      containerIp = "10.0.0.5";
      containerIp6 = "fc00::5";
      domain = "location.joshuabell.xyz";
    };

    matrix = {
      synapsePort = 8008;
      elementPort = 80;
      serverName = "matrix.joshuabell.xyz";
      elementDomain = "element.joshuabell.xyz";
      dataDir = "/var/lib/matrix";
      containerIp = "10.0.0.6";
      # UIDs/GIDs for services inside the matrix container
      postgresUid = 71;
      postgresGid = 71;
      synapseUid = 198;
      synapseGid = 198;
      bridges = {
        gmessages = { port = 29336; uid = 992; gid = 992; enabled = true; };
        signal = { port = 29328; uid = 991; gid = 991; enabled = true; };
        discord = { port = 29334; uid = 987; gid = 987; enabled = true; };
        instagram = { port = 29320; uid = 990; gid = 985; enabled = false; };
        facebook = { port = 29321; uid = 989; gid = 985; enabled = false; };
        whatsapp = { port = 29318; uid = 988; gid = 988; enabled = true; };
        telegram = { port = 29317; uid = 986; gid = 986; enabled = false; };
      };
    };

    opengist = {
      port = 6157;
      dataDir = "/var/lib/opengist";
      domain = "gist.joshuabell.xyz";
    };

    litellm = {
      port = 8094;
      dataDir = "/var/lib/litellm";
      domain = null; # No public domain, accessed via Tailscale
    };

    litellmPublic = {
      port = 8095;
      dataDir = "/var/lib/litellm-public";
      domain = "llm.joshuabell.xyz";
    };

    openWebui = {
      port = 8084;
      domain = "chat.joshuabell.xyz";
    };

    trilium = {
      port = 9111;
      overlayPort = 9112;
      dataDir = "/var/lib/trilium";
      domain = "notes.joshuabell.xyz";
      blogDomain = "blog.joshuabell.xyz";
    };

    oauth2Proxy = {
      port = 4180;
      domain = "sso-proxy.joshuabell.xyz";
    };

    n8n = {
      port = 5678;
      domain = "n8n.joshuabell.xyz";
    };

    beszelHub = {
      port = 8090;
    };

    openbao = {
      port = 8200;
      dataDir = "/var/lib/openbao";
      keysDir = "/bao-keys";
      domain = "sec.joshuabell.xyz";
    };

    homepage = {
      port = 8082;
    };

    puzzles = {
      port = 8093;
      domain = "puzzles.joshuabell.xyz";
    };

    etebase = {
      dataDir = "/var/lib/etebase-server";
      domain = "etebase.joshuabell.xyz";
      webDomain = "pim.joshuabell.xyz";
    };

    youtarr = {
      externalPort = 3087;
      internalPort = 3011;
      dbPort = 3321;
      uid = 187;
      gid = 187;
      dataDir = "/var/lib/youtarr";
      mediaDir = "/nfs/h002/youtarr/media";
    };

    nixarr = {
      jellyfinPort = 8096;
      jellyseerrPort = 5055;
      transmissionPeerPort = 51820;
      mediaDir = "/nfs/h002/nixarr/media";
      stateDir = "/var/lib/nixarr/state";
      jellyfinDomain = "jellyfin.joshuabell.xyz";
      jellyseerrDomain = "media.joshuabell.xyz";
    };

    # Test containers (non-critical)
    wasabi = {
      containerIp = "10.0.0.111";
    };

    ntest = {
      port = 8085;
    };
  };

  secrets = {
    litellm-env = {
      owner = "root";
      group = "root";
      mode = "0400";
      softDepend = [ "litellm" ];
      template = ''
        {{- with secret "kv/data/machines/high-trust/openrouter_2026-03-15" -}}
        OPENROUTER_API_KEY={{ index .Data.data "api-key" }}
        {{- end -}}
      '';
    };

    # SSH keys
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

    # Tailnet auth
    headscale_auth_2026-03-15 = {
      softDepend = [ "tailscaled" ];
      configChanges = {
        services.tailscale.authKeyFile = "$SECRET_PATH";
      };
    };

    # GitHub token for nix
    github_read_token_2026-03-15 = {
      configChanges = {
        nix.extraOptions = "!include $SECRET_PATH";
      };
    };

    # Service secrets
    linode_rw_domains_2026-03-15 = {
      configChanges = {
        security.acme.certs."joshuabell.xyz".credentialFiles.LINODE_TOKEN_FILE = "$SECRET_PATH";
      };
    };

    us_chi_wg_2026-03-15 = {
      configChanges = {
        nixarr.vpn.wgConf = "$SECRET_PATH";
      };
    };

    zitadel_master_key_2026-03-15 = {
      mode = "0444";
      template = ''
        {{- with secret "kv/data/machines/high-trust/zitadel_master_key_2026-03-15" -}}{{- .Data.data.value | base64Decode -}}{{- end -}}
      '';
    };

    oauth2_proxy_key_file_2026-03-15 = {
      configChanges = {
        services.oauth2-proxy.keyFile = "$SECRET_PATH";
      };
    };

    openwebui_env_2026-03-15 = {
      softDepend = [ "open-webui" ];
    };

    openrouter_2026-03-15 = {
      field = "api-key";
    };
  };
}
