{
  pkgs,
  ...
}:
{
  environment.variables = {
    # For CLI
    BAO_ADDR = "http://127.0.0.1:8200";
  };

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

  services.openbao = {
    enable = true;
    package = pkgs.openbao;

    settings = {
      ui = true;

      listener.default = {
        type = "tcp";
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
  # systemd.tmpfiles.rules = [
  #   "d /var/lib/openbao 0700 openbao openbao - -"
  # ];

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

  # AUTO UNSEAL
  systemd.services.openbao-auto-unseal = {
    description = "Auto-unseal OpenBao using stored unseal key shares";
    partOf = [ "openbao.service" ];
    after = [ "openbao.service" ];
    wants = [ "openbao.service" ];
    wantedBy = [ "multi-user.target" "openbao.service" ];
    path = [
      pkgs.openbao
      pkgs.gnugrep
    ];
    environment = {
      BAO_ADDR = "http://127.0.0.1:8200";
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";

      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadOnlyPaths = [ "/bao-keys" ];
      NoNewPrivileges = true;

      ExecStart = pkgs.writeShellScript "openbao-auto-unseal" ''
        #!/usr/bin/env bash
        echo "Auto-unseal: waiting for OpenBao to be reachable"

        # Wait for OpenBao to be listening & initialized
        for i in {1..30}; do
          BAO_STATUS=$(bao status 2>/dev/null);
          # echo "Current status:"
          # echo "$BAO_STATUS"

          # Check if initialized
          if grep -qi 'initialized.*true' <<< "$BAO_STATUS"; then
            echo "OpenBao is initialized"
            break
          fi
          sleep 1
        done

        # Check again; if still not initialized, bail
        BAO_STATUS=$(bao status 2>/dev/null);
        if ! grep -qi 'initialized.*true' <<< "$BAO_STATUS"; then
          echo "OpenBao is not initialized yet; skipping auto-unseal" >&2
          exit 1
        fi

        # If it's already unsealed, exit
        if grep -qi 'sealed.*false' <<< "$BAO_STATUS"; then
          echo "OpenBao already unsealed; nothing to do"
          exit 0
        fi

        echo "OpenBao is sealed; applying unseal key shares"

        # Apply each unseal key share; ignore "already unsealed" errors
        for key in /bao-keys/openbao-unseal-*; do
          if [ -f "$key" ]; then
            echo "Unsealing with key $key"
            bao operator unseal "$(cat "$key")" || true
          fi
        done

        # Final status check
        if ! BAO_STATUS=$(bao status 2>/dev/null); then
          echo "OpenBao not responding after unseal attempts" >&2
          exit 1
        fi
        # echo "Final status:"
        # echo "$BAO_STATUS"
        if grep -qi 'sealed.*true' <<< "$BAO_STATUS"; then
          echo "OpenBao is still sealed after applying unseal keys" >&2
          exit 1
        fi

        echo "Successfully unsealed OpenBao"
      '';
    };
  };
}
