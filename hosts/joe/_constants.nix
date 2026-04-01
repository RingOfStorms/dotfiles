{
  host = {
    name = "joe";
    overlayIp = "100.64.0.12";
    primaryUser = "josh";
    stateVersion = "26.05";
  };

  services = {
    ollama = {
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
    minecraft = {
      port = 25565;
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
