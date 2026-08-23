# Host-specific sec-agent additions for juni.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
    "atuin-key-josh_2026-03-15" = {
      remotePath = "machines/high-trust/atuin-key-josh_2026-03-15";
      field = "value";
      owner = "josh";
      group = "users";
      mode = "0400";
      hardDepend = [ "atuin-autologin" ];
    };
  };
}
