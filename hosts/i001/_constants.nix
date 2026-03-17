# Service constants for i001 (Intel NUC - Testbed)
# Impermanence-enabled, low-trust device.
{
  host = {
    name = "i001";
    primaryUser = "luser";
    stateVersion = "25.11";
  };

  secrets = {
    "headscale_auth_lowtrust_2026-03-15" = {
      kvPath = "kv/data/machines/low-trust/headscale_auth_lowtrust_2026-03-15";
      softDepend = [ "tailscaled" ];
      configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
    };
  };
}
