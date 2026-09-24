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
    bunny_rw_dns_2026-03-15 = {
      remotePath = "machines/high-trust/bunny_rw_dns_2026-03-15";
      softDepend = [ "acme-order-renew-joshuabell.xyz.service" ];
      configChanges.security.acme.certs."joshuabell.xyz".credentialFiles.BUNNY_API_KEY_FILE = "$SECRET_PATH";
    };
  };
}
