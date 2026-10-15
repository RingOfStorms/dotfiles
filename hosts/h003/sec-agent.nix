# Host-specific sec-agent additions for h003.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
    # Credentials of the shared `josh` atuin account, readable by the local
    # primary user's atuin-autologin.
    "atuin-key-josh_2026-03-15" = {
      remotePath = "machines/high-trust/atuin-key-josh_2026-03-15";
      field = "value";
      owner = constants.host.primaryUser;
      group = "users";
      mode = "0400";
      hardDepend = [ "atuin-autologin" ];
    };

    hass_isp_speedtest_token = {
      remotePath = "machines/by-host/h003/hass_isp_speedtest_token";
      softDepend = [ "h003-isp-speedtest" ];
    };

    # Shared with h001 for the ACME DNS-01 credential and used here by DDNS.
    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      softDepend = [ "ddns-update" ];
    };
  };
}
