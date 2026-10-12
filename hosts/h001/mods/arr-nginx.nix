# Host-side pieces of the `arr` floating container (containers/arr): the
# vhosts that nixarr.nix/kavita.nix/media-integrity.nix declared while the
# stack ran on the host. The container shares the host network, so the
# backends are on the same ports.
{ constants, fleet, ... }:
let
  c = constants.services.nixarr;
  mi = constants.services.mediaIntegrity;
  tls = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
  };
  proxy = port: {
    proxyWebsockets = true;
    recommendedProxySettings = true;
    proxyPass = "http://127.0.0.1:${toString port}";
  };
in
{
  services.nginx.virtualHosts = {
    "${c.jellyfinDomain}" = tls // {
      locations."/" = proxy c.jellyfinPort;
    };
    "${c.jellyseerrDomain}" = tls // {
      locations."/" = proxy c.jellyseerrPort;
    };
    "books.${fleet.global.domain}" = tls // {
      locations."/" = proxy c.kavitaPort;
    };
    "h001.net.${fleet.global.domain}".locations."${mi.webPath}" = {
      alias = "/srv/containers/${c.containerName}/${baseNameOf mi.dataDir}/";
      extraConfig = ''
        index index.html;
        autoindex off;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
      '';
    };
  };
}
