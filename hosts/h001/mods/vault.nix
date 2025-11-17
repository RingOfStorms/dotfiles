{
  config,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [ vault-bin campground.vault-scripts];
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
    package = pkgs.vault-bin;
    dev = true; # trying it out... remove
    address = "127.0.0.1:8200";
    # storagePath = "/var/lib/hashi_vault";
  };
  users.users.vault.uid =lib.mkForce 116;
  users.groups.vault.gid = lib.mkForce 116;

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
