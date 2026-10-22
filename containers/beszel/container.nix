# Guest config: the nixpkgs beszel-hub module. Private network: 0.0.0.0 in
# the guest netns (host DNAT from 100.64.0.13:8090); host network: h001's
# tailnet IP as before.
{ lib, fleetNet, ... }:
let
  fleet = import ../../hosts/fleet.nix;
in
{
  system.stateVersion = "25.11";

  services.beszel.hub = {
    enable = true;
    host = if fleetNet.private then "0.0.0.0" else fleet.hosts.h001.overlayIp;
    port = 8090;
  };

  # Static user instead of DynamicUser: the persisted files keep a fixed owner.
  users.users.beszel-hub = {
    isSystemUser = true;
    group = "beszel-hub";
    uid = 958;
  };
  users.groups.beszel-hub.gid = 958;
  systemd.services.beszel-hub.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "beszel-hub";
    Group = "beszel-hub";
    # The tailnet IP may not exist yet when the container starts (host
    # network; tailscaled runs on the host). systemd has no IPFreeBind for
    # services, so just retry until the bind succeeds.
    Restart = lib.mkForce "always";
    RestartSec = lib.mkForce 5;
  };
  systemd.services.beszel-hub.unitConfig = {
    StartLimitIntervalSec = 0;
  };
}
