{
  constants,
  pkgs,
  ...
}:
let
  c = constants.services.ollama;
in
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    host = "0.0.0.0";
    port = c.port;
  };

  # Allow access from Tailscale overlay and LAN
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ c.port ];
  networking.firewall.allowedTCPPorts = [ c.port ];
}
