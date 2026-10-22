# Host-specific sec-agent additions for lio.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
    # Fleet restic repo (same repo + password as h001) for per-service
    # backups (ringofstorms.containers.backup, ROUTING-PLAN §9.1). The key
    # name is historical; it already carries a device_high_trust grant.
    restic_h001_env_2026-10-01 = {
      remotePath = "machines/high-trust/restic_h001_env_2026-10-01";
      configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH";
    };
  };
}
