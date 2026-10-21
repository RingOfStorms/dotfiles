{
  host = {
    name = "joe";
    overlayIp = "100.64.0.12";
    primaryUser = "josh";
    stateVersion = "26.05";
  };

  services = { };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  secrets = { };
}
