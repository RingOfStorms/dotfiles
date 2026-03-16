{
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
    template = ''
      {{- with secret "kv/data/machines/high-trust/nix2nix_2026-03-15" -}}{{- .Data.data.value | base64Decode -}}{{- end -}}
    '';
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
    template = ''
      {{- with secret "kv/data/machines/high-trust/nix2github_2026-03-15" -}}{{- .Data.data.value | base64Decode -}}{{- end -}}
    '';
    hmChanges = {
      programs.ssh.matchBlocks."github.com".identityFile = "$SECRET_PATH";
    };
  };

  nix2gitforgejo_2026-03-15 = {
    owner = "luser";
    group = "users";
    template = ''
      {{- with secret "kv/data/machines/high-trust/nix2gitforgejo_2026-03-15" -}}{{- .Data.data.value | base64Decode -}}{{- end -}}
    '';
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
}
