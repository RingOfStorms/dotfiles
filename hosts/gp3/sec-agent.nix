# Host-specific sec-agent additions for gp3.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-lowtrust";
  extraSecrets = {
    hass_token = {
      remotePath = "machines/by-host/gp3/hass_token";
      softDepend = [ "battery-manager" ];
    };
  };
}
