# Service constants for o001 (Oracle Cloud - Public Gateway)
# Single source of truth for ports, UIDs/GIDs, data paths.
{
  host = {
    name = "o001";
    overlayIp = "100.64.0.11";
    primaryUser = "root";
    stateVersion = "23.11";
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
    litellm_public_api_key_2026-03-15 = {
      group = "nginx";
      mode = "0440";
      template = ''
        {{- with secret "kv/data/machines/high-trust/litellm_public_api_key_2026-03-15" -}}
        if ($http_authorization != "Bearer {{ index .Data.data "value" }}") { return 401; }
        {{- end -}}
      '';
    };

    vaultwarden_env_2026-03-15 = { };
  };
}
