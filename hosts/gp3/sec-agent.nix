# Host-specific sec-agent additions for gp3.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-lowtrust";
  extraSecrets = { };
}
