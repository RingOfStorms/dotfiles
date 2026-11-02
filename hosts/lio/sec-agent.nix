# Host-specific sec-agent additions for lio.
{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
    # Shared with h001 for per-service backups. Despite its host-specific
    # name, this key has a device_high_trust grant.
    restic_h001_env_2026-10-01 = {
      remotePath = "machines/high-trust/restic_h001_env_2026-10-01";
      configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH";
    };
  };
}
