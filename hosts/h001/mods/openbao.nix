{
  config,
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
    after = [ "openbao.service" ];
    wants = [ "openbao.service" ];
    # Run once at boot; doesn't restart
    serviceConfig = {
      Type = "oneshot";
      # run as the same user as the openbao service
      # User = config.systemd.services.openbao.User;
      # Group = config.systemd.services.openbao.Group;
      # /run/keys/... are usually readable by root only; you might prefer to run as root
      User = "root";
      Group = "root";

      # Only needs network access to 127.0.0.1
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadOnlyPaths = [ "/" ];
      # allow reading /run/keys and talking to localhost
      ReadWritePaths = [ "/run" ];
      NoNewPrivileges = true;

      ExecStart = pkgs.writeShellScript "openbao-auto-unseal" ''
        #!/usr/bin/env bash
        set -euo pipefail

        export BAO_ADDR="http://127.0.0.1:8200"

        # Wait for OpenBao to be listening
        # (systemd "after" ensures start order but not readiness)
        for i in {1..30}; do
          if bao status >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done

        # If it's already unsealed, exit
        if bao status 2>/dev/null | grep -q 'sealed *false'; then
          exit 0
        fi

        # Apply each unseal key share; ignore "already unsealed" errors
        # TODO change this back to /run/agenix instead of /root/bao-keys
        for key in /root/bao-keys/openbao-unseal-*; do
          if [ -f "$key" ]; then
            bao operator unseal "$(cat "$key")" || true
          fi
        done

        # Check final status; fail if still sealed
        if bao status 2>/dev/null | grep -q 'sealed *true'; then
          echo "OpenBao is still sealed after applying unseal keys" >&2
          exit 1
        fi
      '';
    };
    wantedBy = [ "multi-user.target" ];
  };
}
