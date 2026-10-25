# Host-specific sec-agent additions for h004.
{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  # H2: h004 is an SSH/NFS target only (NAS + rsync-over-ssh backup
  # destination, hosts/h004/nfs-data.nix); it never initiates
  # nix2nix/nix2github/nix2gitforgejo SSH, so it doesn't need those keys.
  includeFleetSshKeys = false;
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
