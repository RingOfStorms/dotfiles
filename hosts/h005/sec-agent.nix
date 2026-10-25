# Host-specific sec-agent additions for h005.
{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # H2: h005 is the router; it never initiates arbitrary root SSH or git
  # pushes. It only runs wildcard-push and ups-shutdown, each with its own
  # dedicated restricted key below.
  includeFleetSshKeys = false;
  extraSecrets = {
    # Credentials of the shared `josh` atuin account; owned by the local
    # primary user (luser) so its atuin-autologin can read it.
    "atuin-key-josh_2026-03-15" = {
      remotePath = "machines/high-trust/atuin-key-josh_2026-03-15";
      field = "value";
      owner = constants.host.primaryUser;
      group = "users";
      mode = "0400";
      hardDepend = [ "atuin-autologin" ];
    };
  }
  // inputs.nixpkgs.lib.optionalAttrs constants.network.routerEnable {
    # Dedicated keys (H2), forced to fleet-cert-receive / fleet-ups-shutdown
    # on the receivers (wildcard-cert-receiver.nix, ups-shutdown-receiver.nix).
    wildcard_push_2026-10-22 = {
      remotePath = "machines/by-host/h005/wildcard_push_2026-10-22";
      ensureNewline = true;
    };
    ups_shutdown_2026-10-22 = {
      remotePath = "machines/by-host/h005/ups_shutdown_2026-10-22";
      ensureNewline = true;
    };

    hass_isp_speedtest_token = {
      remotePath = "machines/by-host/h005/hass_isp_speedtest_token";
      softDepend = [ "h005-isp-speedtest" ];
    };

    # Fleet oauth2-proxy (oauth2-proxy.nix): same env file as the legacy
    # trilium instance on h001 (client id/secret + cookie secret).
    # Loaded via systemd EnvironmentFile (root), so default owner/mode.
    oauth2_proxy_key_file_2026-03-15 = {
      remotePath = "machines/high-trust/oauth2_proxy_key_file_2026-03-15";
      softDepend = [ "oauth2-proxy" ];
    };

    # Shared with h001's ACME DNS-01 credential. Also DNS-01 for the
    # private-zone wildcard *.ts.joshuabell.xyz (private-zone.nix).
    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      softDepend = [ "ddns-update" ];
      configChanges.security.acme.certs."ts.joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE =
        "$SECRET_PATH";
      # Public wildcard (wildcard-cert.nix), pushed to o002 and h001.
      configChanges.security.acme.certs."joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE =
        "$SECRET_PATH";
    };
  };
}
