# Guest config. Host network: trilium on 127.0.0.1:9111, oauth2-proxy on
# 127.0.0.1:4180; only h001's nginx (service.nix) is reachable from outside.
{ ... }:
{
  system.stateVersion = "24.11";

  # Same ids as on h001 bare metal, so the copied files keep working.
  users.users.trilium.uid = 989;
  users.groups.trilium.gid = 985;

  services.trilium-server = {
    enable = true;
    host = "127.0.0.1";
    port = 9111;
    dataDir = "/var/lib/trilium";
    # Auth is oauth2-proxy (nginx auth_request); never expose 9111 directly.
    noAuthentication = true;
    instanceName = "joshuabell";
  };
  systemd.services.trilium-server.environment.TRILIUM_NO_UPLOAD_LIMIT = "true";

  services.oauth2-proxy = {
    enable = true;
    httpAddress = "http://127.0.0.1:4180";
    trustedProxyIP = [ "127.0.0.1" ];
    provider = "oidc";
    reverseProxy = true;
    redirectURL = "https://sso-proxy.joshuabell.xyz/oauth2/callback";
    validateURL = "https://sso.joshuabell.xyz/oauth2/";
    oidcIssuerUrl = "https://sso.joshuabell.xyz";
    # Cookie secret + client id/secret, bound read-only from h001's sec-agent
    # output (see flake.nix).
    keyFile = "/var/secrets/oauth2-proxy.env";
    email.domains = [ "*" ];
    extraConfig = {
      whitelist-domain = "*.joshuabell.xyz";
      cookie-domain = ".joshuabell.xyz";
      oidc-groups-claim = "flatRolesClaim";
    };
    cookie.refresh = "12h";
  };
}
