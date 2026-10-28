# Host-specific sec-agent additions for h005.
{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # H2: h005 is the router; it never initiates nix2nix (fleet root SSH).
  # It only runs wildcard-push and ups-shutdown, each with its own
  # dedicated restricted key below. includeGitKeys (default true) stays on
  # for any git+ssh flake fetches.
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
    edge_vhost_push_2026-10-24 = {
      remotePath = "machines/by-host/h005/edge_vhost_push_2026-10-24";
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

    # Shared with h001's ACME DNS-01 credential (private zone retired:
    # FLOWS-AUDIT target design (a); the only certs h005 issues now are the
    # public wildcard and the share wildcard, both below).
    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      softDepend = [ "ddns-update" ];
      # Public wildcard (wildcard-cert.nix), pushed to every container host
      # plus o002.
      configChanges.security.acme.certs."joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE =
        "$SECRET_PATH";
      # *.share.joshuabell.xyz (wildcard-cert.nix), pushed to o002 only
      # (FLOWS-AUDIT.md §c).
      configChanges.security.acme.certs."share.joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE =
        "$SECRET_PATH";
    };
  };
}
