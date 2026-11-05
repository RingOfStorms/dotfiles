# Self-hosted iroh relay (n0's official `iroh-relay` server) for
# tmux-agents-mobile's go-iroh transport: our endpoints use only this relay,
# never n0's public relays or DNS discovery.
#
# nginx terminates TLS for relay.<domain> (the wildcard cert h005 pushes) and proxies the relay's
# WebSocket upgrade to a loopback-only plain-HTTP listener. Browsers can only
# reach a relay over WebSocket, so QUIC address discovery (UDP, needs the
# relay's own TLS) stays off.
#
# Telemetry/logging: the relay has no phone-home. Its Prometheus endpoint is
# disabled; logs go to journald only (RUST_LOG=warn).
#
# Access: `everyone`. A browser cannot set the Authorization header on a
# WebSocket upgrade, so shared_token would lock out the phone. The relay only
# forwards end-to-end-encrypted QUIC between endpoint IDs; the app decides
# which endpoint IDs it accepts.
{
  config,
  lib,
  pkgs,
  fleet,
  ...
}:
let
  domain = fleet.global.domain;
  hostname = "relay.${domain}";
  port = 3340;

  # nixpkgs (26.05) ships 0.98.2; go-iroh tracks wire v1 (tested against 1.2/1.3).
  iroh-relay = pkgs.iroh-relay.overrideAttrs (old: rec {
    version = "1.3.0";
    src = pkgs.fetchFromGitHub {
      owner = "n0-computer";
      repo = "iroh";
      rev = "v${version}";
      hash = "sha256-ugGYRESccGgkI8evd21NE3jzNgULDEHwuf0UWdqKp6A=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "iroh-relay-${version}-vendor";
      hash = "sha256-L0OnbXUC8JNW+/Xm0Q/8EjSlGmKYGvQQM+SqrRLb8mQ=";
    };
  });

  relayConfig = (pkgs.formats.toml { }).generate "iroh-relay.toml" {
    enable_relay = true;
    http_bind_addr = "127.0.0.1:${toString port}";
    enable_quic_addr_discovery = false;
    enable_metrics = false;
    access = "everyone";
    limits = {
      accept_conn_limit = 10.0;
      accept_conn_burst = 20;
    };
  };
in
{
  systemd.services.iroh-relay = {
    description = "iroh relay server (relay.${domain})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment.RUST_LOG = "warn";
    serviceConfig = {
      ExecStart = "${iroh-relay}/bin/iroh-relay --config-path ${relayConfig}";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
    };
  };

  services.nginx.virtualHosts.${hostname} = config.fleet.wildcardTls // {
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        # Relay traffic is opaque ciphertext; don't log every connection.
        access_log off;
      '';
    };
  };
}
