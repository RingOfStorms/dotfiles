{
  ...
}:
{
  options = { };
  config = {
    services.nginx.virtualHosts = {
      "n8n.joshuabell.xyz" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
        locations = {
          "/" = {
            proxyWebsockets = true;
            recommendedProxySettings = true;
            proxyPass = "http://127.0.0.1:5678";
          };
        };
      };
    };

    # Expose litellm to my overlay network as well
    # networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

    services.n8n = {
      enable = true;
    };
    systemd.services.n8n.environment = {
      # N8N_SECURE_COOKIE = "false";
      N8N_LISTEN_ADDRESS = "127.0.0.1";
      N8N_EDITOR_BASE_URL = "https://n8n.joshuabell.xyz/";
      N8N_HOST = "n8n.joshuabell.xyz";
      VUE_APP_URL_BASE_API = "https://n8n.joshuabell.xyz/";
      N8N_HIRING_BANNER_ENABLED = "false";
      # N8N_PUBLIC_API_DISABLED = "true";
      # N8N_PUBLIC_API_SWAGGERUI_DISABLED = "true";
    };
  };
}
