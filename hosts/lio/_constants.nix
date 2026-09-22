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
    paseo = {
      port = 6767;
      uid = 983;
      gid = 983;
      dataDir = "/var/lib/paseo";
      projectsDir = "/var/lib/paseo-projects";
      containerIp = "10.0.0.12";
      containerIp6 = "fc00::12";
      # Private by default: use the tailnet address or an SSH tunnel.
      domain = null;
    };
  };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  secrets = { };
}
