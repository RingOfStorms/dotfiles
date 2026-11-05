# Host-specific sec-agent additions for lio.
{ inputs, constants, ... }:
import ../_shared_assets/utilities/sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = (import ../../containers/backup-subjects.nix).clientSecrets "lio" // {
  };
}
