{
  host = {
    name = "joe";
    overlayIp = "TODO"; # Assign headscale overlay IP later
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
