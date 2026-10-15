# Host-specific sec-agent additions for h004.
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
  };
}
