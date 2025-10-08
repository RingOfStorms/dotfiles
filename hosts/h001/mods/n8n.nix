{
  ...
}:
let
  port = 5678;
in
{
  options = { };
  config = {
    services.nginx.virtualHosts = {
      "n8n.joshuabell.xyz" = {
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:${port}";
          };
        };
      };
    };

    # Expose litellm to my overlay network as well
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

    services.n8n = {
      enable = true;
    };
    systemd.services.n8n.environment = {
      # N8N_SECURE_COOKIE = "false";
      N8N_EDITOR_BASE_URL = "https://n8n.joshuabell.xyz/";
    };
  };
}
