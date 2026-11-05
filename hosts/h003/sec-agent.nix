{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # Deploys originate on operator workstations; this host needs no fleet
  # root SSH key. Git+SSH flake inputs still need includeGitKeys.
  includeFleetSshKeys = false;
  extraSecrets = (import ../../containers/backup-subjects.nix).clientSecrets "h003" // {
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
  };
}
