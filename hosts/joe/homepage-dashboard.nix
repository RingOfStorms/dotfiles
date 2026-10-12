{ constants, ... }:
let
  section1 = "a. AI / Creative";

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
            "LocalAI" = {
              description = "Image generation + TTS API";
              href = "http://localhost:8080";
              icon = "si-openai";
            };
          }
        ];
      }
    ];
  };
}
