# Host-specific sec-agent additions for gp3.
{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
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

    # Restricted key for nix-builder@lio (remote_lio_builds.nix).
    remote_lio_builds_2026-10-22 = {
      remotePath = "machines/high-trust/remote_lio_builds_2026-10-22";
      ensureNewline = true;
    };
  };
}
