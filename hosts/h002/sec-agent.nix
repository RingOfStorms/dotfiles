# h002 has no host-specific secrets; the shared high-trust sec-agent
# definition replaces its old secrets-bao auto-secrets.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
}
