# Host-specific sec-agent additions for h003.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
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
