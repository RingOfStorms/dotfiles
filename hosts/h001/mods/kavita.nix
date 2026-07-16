{
  constants,
  fleet,
  pkgs,
  ...
}:
let
  c = constants.services.nixarr;
  domain = "books.joshuabell.xyz";
in
{
  # Generate a persistent signing key on the host; it is intentionally not
  # stored in the repository. The service module loads it using systemd
  # credentials before Kavita starts.
  system.activationScripts.kavitaToken.text = ''
    install -d -m 0750 /var/lib/kavita
    if [ ! -e /var/lib/kavita/token-key ]; then
      umask 077
      ${pkgs.coreutils}/bin/head -c 64 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w 0 > /var/lib/kavita/token-key
    fi
  '';

  services.kavita = {
    enable = true;
    tokenKeyFile = "/var/lib/kavita/token-key";
    settings = {
      Port = c.kavitaPort;
      IpAddresses = "127.0.0.1";
    };
  };

  # Kavita indexes the existing Shelfmark books destination. Create libraries
  # and select this directory from Kavita's first-run web UI.
  systemd.services.kavita = {
    after = [ "remote-fs.target" ];
    wants = [ "remote-fs.target" ];
    serviceConfig.SupplementaryGroups = [ "media" ];
  };

  services.nginx.virtualHosts."${domain}" = {
    addSSL = true;
    sslCertificate = "/var/lib/acme/${fleet.global.domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${fleet.global.domain}/key.pem";
    locations."/" = {
      proxyWebsockets = true;
      recommendedProxySettings = true;
      proxyPass = "http://127.0.0.1:${toString c.kavitaPort}";
    };
  };
}
