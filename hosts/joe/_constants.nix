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
    sunshine = {
      port = 47989;
      webUiPort = 47990;
      tcpPorts = [ 47984 47989 47990 48010 ];
      udpPorts = [ 47998 47999 48000 48002 48010 ];
    };
    homepage = {
      port = 8082;
    };
  };
}
