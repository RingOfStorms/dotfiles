{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # This NAS receives SSH/NFS traffic but initiates no fleet root SSH.
  # Git+SSH flake inputs still need includeGitKeys.
  includeFleetSshKeys = false;
  extraSecrets = {
    # B2 app key of the backup pusher (bucket-restricted, prefix svc-).
    "restic_b2_h004_2026-11-11" = {
      remotePath = "machines/by-host/h004/restic_b2_h004_2026-11-11";
    };
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
