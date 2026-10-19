# Host-specific sec-agent additions for h005.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
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
  } // inputs.nixpkgs.lib.optionalAttrs constants.network.routerEnable {
    hass_isp_speedtest_token = {
      remotePath = "machines/by-host/h005/hass_isp_speedtest_token";
      softDepend = [ "h005-isp-speedtest" ];
    };

    # Shared with h001's ACME DNS-01 credential. Also DNS-01 for the
    # private-zone wildcard *.ts.joshuabell.xyz (private-zone.nix).
    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      softDepend = [ "ddns-update" ];
      configChanges.security.acme.certs."ts.joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE =
        "$SECRET_PATH";
    };
  };
}
