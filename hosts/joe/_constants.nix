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
    minecraft = {
      port = 25565;
    };
  };
}
