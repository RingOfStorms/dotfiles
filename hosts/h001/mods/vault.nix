{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.nginx = {
    virtualHosts = {
      "sec.joshuabell.xyz" = {
        addSSL = true;
        sslCertificate = "/var/lib/acme/joshuabell.xyz/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/joshuabell.xyz/key.pem";
        locations."/" = {
          proxyWebsockets = true;
          proxyPass = "http://localhost:8200";
          recommendedProxySettings = true;
        };
      };
    };
  };

  services.vault = {
    enable = true;
    dev = true; # trying it out... remove
    address = "127.0.0.1:8200";
    storagePath = "/var/lib/hashi_vault";

     };

  # Ensure the data directory exists with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/hashi_vault 0700 vault vault - -"
  ];

  # Additional systemd service hardening
  # systemd.services.openbao = {
  #   serviceConfig = {
  #     # Security hardening
  #     NoNewPrivileges = true;
  #     PrivateTmp = true;
  #     ProtectSystem = "strict";
  #     ProtectHome = true;
  #     ReadWritePaths = [ "/var/lib/openbao" ];
  #
  #     # Resource limits
  #     LimitNOFILE = 65536;
  #     LimitNPROC = 4096;
  #   };
  # };
}
