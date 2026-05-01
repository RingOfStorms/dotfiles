{
  host = {
    name = "joe";
    overlayIp = "100.64.0.12";
    primaryUser = "josh";
    stateVersion = "26.05";
  };

  services = {
    llama-cpp = {
      port = 11434;
    };
    kokoro-tts = {
      port = 8880;
      dataDir = "/var/lib/kokoro-tts";
    };
    forge = {
      port = 7860;
      dataDir = "/var/lib/forge";
    };
    homepage = {
      port = 8082;
    };
    krdp = {
      port = 3389;
    };
  };

  # ── Per-host secrets (merged with mkAutoSecrets in fleet.mkHost) ────
  secrets = {
    # Password for the KRDP user systemd unit. The same value should
    # also live at machines/high-trust/guacamole_joe_krdp_2026-05-01
    # (rendered on h001) so Guacamole can connect.
    "krdp_password" = {
      kvPath = "kv/data/machines/by-host/joe/krdp_password";
      owner = "josh";
      group = "users";
      softDepend = [ "krdpserver" ]; # noop for user units, but harmless
    };
  };
}
