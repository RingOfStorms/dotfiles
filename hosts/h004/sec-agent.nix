{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # This NAS receives SSH/NFS traffic but initiates no fleet root SSH.
  # Git+SSH flake inputs still need includeGitKeys.
  includeFleetSshKeys = false;
  extraSecrets = (import ../../containers/backup-subjects.nix).targetSecrets // {
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
    # Backup target login for svc-canary (BACKUP-PLAN P1); rendered into
    # rest-server's htpasswd.
    "restic_svc-canary_2026-11-04" = {
      remotePath = "machines/backup/restic_svc-canary_2026-11-04";
      field = "value";
      mode = "0400";
      hardDepend = [ "render-htpasswd" ];
    };
  };
}
