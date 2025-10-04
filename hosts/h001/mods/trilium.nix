{
  ...
}:
{
  config = {
    services.trilium-server = {
      enable = true;
      port = 9111;
      host = "127.0.0.1";
      dataDir = "/var/lib/trilium";
      noAuthentication = true;
      instanceName = "joshuabell";
    };

    systemd.services.trilium-server.environment = {
      TRILIUM_NO_UPLOAD_LIMIT = "true";
    };

    services.oauth2-proxy.nginx.virtualHosts."notes.joshuabell.xyz".allowed_groups = [ "notes" ];
    services.nginx.virtualHosts."notes.joshuabell.xyz" = {
      locations = {
        "/" = {
          proxyWebsockets = true;
          recommendedProxySettings = true;
          proxyPass = "http://127.0.0.1:9111";
          extraConfig = ''
            auth_request /oauth2/auth;
            error_page 401 = @error401;

            location = /oauth2/auth {
              internal;
              proxy_pass https://sso-proxy.joshuabell.xyz/oauth2/auth;
              proxy_set_header Host sso-proxy.joshuabell.xyz;
              proxy_set_header X-Auth-Request-Redirect $request_uri;
              proxy_set_header X-Forwarded-Proto https;
            }

            location @error401 {
              return 302 https://sso-proxy.joshuabell.xyz/oauth2/start?rd=https://$host$request_uri;
            }
          '';
        };
      };
    };

    # services.nginx = {
    #   virtualHosts = {
    #     "trilium" = {
    #       serverName = "h001.net.joshuabell.xyz";
    #       listen = [
    #         {
    #           port = 9111;
    #           addr = "0.0.0.0";
    #         }
    #       ];
    #       locations."/" = {
    #         proxyWebsockets = true;
    #         recommendedProxySettings = true;
    #         proxyPass = "http://127.0.0.1:9111";
    #       };
    #     };
    #   };
    # };
  };
}
