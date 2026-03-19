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
}
