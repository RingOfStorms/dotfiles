# Host-specific sec-agent additions for lio.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
  extraSecrets = {
    paseo_agent_env_2026-09-21 = {
      remotePath = "machines/high-trust/paseo_agent_env_2026-09-21";
      softDepend = [ "paseo.service" ];
    };
  };
}
