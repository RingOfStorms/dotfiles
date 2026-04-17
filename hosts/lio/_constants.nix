# Service constants for lio (System76 Thelio - Primary Workstation)
# Single source of truth for ports, data paths, and service configuration.
{
  host = {
    name = "lio";
    overlayIp = "100.64.0.1";
    primaryUser = "josh";
    stateVersion = "23.11";
  };

  services = {
    nixServe = {
      port = 5000;
      secretKeyFile = "/var/lib/nix-serve/cache-priv-key.pem";
    };
    ttyd = {
      port = 8080;
    };
    homepage = {
      port = 8082;
    };
  };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  secrets = {
    "rustdesk_server_key" = {
      kvPath = "kv/data/machines/low-trust/rustdesk_server_key";
      softDepend = [ "rustdesk" ];
    };
    "rustdesk_password" = {
      kvPath = "kv/data/machines/low-trust/rustdesk_password";
      softDepend = [ "rustdesk" ];
    };
  };
}
