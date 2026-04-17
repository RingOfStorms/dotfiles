{ constants, ... }:
let
  section1 = "a. AI / Creative";
  s = constants.services;
in
{
  services.homepage-dashboard = {
    enable = true;
    openFirewall = false;
    allowedHosts = "*";
    settings = {
      title = "joe — Local Services";
      favicon = "https://twenty-icons.com/search.nixos.org";
      color = "neutral";
      theme = "dark";
      iconStyle = "theme";
      headerStyle = "clean";
      hideVersion = true;
      disableUpdateCheck = true;
      language = "en";
      layout = {
        "${section1}" = {
          style = "row";
          columns = 3;
        };
      };
    };
    services = [
      {
        "${section1}" = [
          {
            "Ollama" = {
              description = "LLM Inference (port ${toString s.ollama.port})";
              href = "http://localhost:${toString s.ollama.port}";
              icon = "ollama";
            };
          }
          {
            "Forge" = {
              description = "Stable Diffusion WebUI";
              href = "http://localhost:${toString s.forge.port}";
              icon = "si-stablediffusion";
            };
          }
          {
            "Kokoro TTS" = {
              description = "Text-to-Speech API";
              href = "http://localhost:${toString s.kokoro-tts.port}";
              icon = "mdi-microphone";
            };
          }
        ];
      }
    ];
  };
}
