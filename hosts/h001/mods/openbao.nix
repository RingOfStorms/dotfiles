{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.openbao = {
    enable = true;
    package = pkgs.openbao;
    
    settings = {
      ui = true;
      
      listener.tcp = {
        address = "127.0.0.1:8200";
        tls_disable = true; # nginx will handle TLS
      };
      
      storage.file = {
        path = "/var/lib/openbao";
      };
      
      # Disable mlock requirement for development
      # In production, you may want to enable this
      disable_mlock = true;
    };
  };

  # Ensure the data directory exists with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/openbao 0700 openbao openbao - -"
  ];

  # Additional systemd service hardening
  systemd.services.openbao = {
    serviceConfig = {
      # Security hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/openbao" ];
      
      # Resource limits
      LimitNOFILE = 65536;
      LimitNPROC = 4096;
    };
  };
}
