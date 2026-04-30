# Service constants for h001 (Service Host)
# Single source of truth for ports, UIDs/GIDs, data paths, container IPs, and domains.
# Import this file in flake.nix and pass to service modules via specialArgs or let bindings.
{ fleet }:
{
  # Host-level
  host = {
    name = "h001";
    overlayIp = "100.64.0.13";
    lanIp = "10.12.14.10";
    primaryUser = "luser";
    stateVersion = "24.11";
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

    paperless = {
      port = 28981;
      uid = 915;
      gid = 915;
      dataDir = "/drives/wd10/paperless";
      varLibDir = "/var/lib/paperless";
      containerIp = "10.0.0.7";
      containerIp6 = "fc00::7";
      domain = "docs.joshuabell.xyz";
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

    # LLM gateway bake-off: alternate gateways running alongside litellm
    # for testing. Tailscale-only exposure, same as litellm.
    bifrost = {
      port = 8097; # 8096 taken by jellyfin
      dataDir = "/var/lib/bifrost";
      domain = null;
    };

    portkey = {
      port = 8098;
      dataDir = "/var/lib/portkey";
      domain = null;
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
      # Loopback-only second listener used by openbao-apply-config.service to
      # call `bao operator generate-root` (which is disabled by default on the
      # public-facing listener since OpenBao 2.5.3 / CVE-2026-5807). Never
      # proxied by nginx, never exposed beyond 127.0.0.1.
      adminPort = 8201;
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

    # Service secrets
    linode_rw_domains_2026-03-15 = {
      configChanges = {
        security.acme.certs.${fleet.global.domain}.credentialFiles.LINODE_TOKEN_FILE = "$SECRET_PATH";
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
