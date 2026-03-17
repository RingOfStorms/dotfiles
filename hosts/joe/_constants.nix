{
  host = {
    name = "joe";
    overlayIp = "100.64.0.12";
    primaryUser = "josh";
    stateVersion = "26.05";
  };

  secrets = {
    "headscale_auth_lowtrust_2026-03-15" = {
      kvPath = "kv/data/machines/low-trust/headscale_auth_lowtrust_2026-03-15";
      softDepend = [ "tailscaled" ];
      configChanges.services.tailscale.authKeyFile = "$SECRET_PATH";
    };
  };
}
