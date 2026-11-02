{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # Deploys originate on operator workstations; this host needs no fleet
  # root SSH key. Git+SSH flake inputs still need includeGitKeys.
  includeFleetSshKeys = false;
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

    # fleet-backup credentials (ringofstorms.containers.backup), shared with
    # h001/lio: RESTIC_REPOSITORY, RESTIC_PASSWORD and backend credentials.
    restic_h001_env_2026-10-01 = {
      remotePath = "machines/high-trust/restic_h001_env_2026-10-01";
      configChanges.ringofstorms.containers.backup.environmentFile = "$SECRET_PATH";
    };
  };
}
