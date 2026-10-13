# h004 has no host-specific secrets; same high-trust sec-agent definition as h002.
{ inputs, constants, ... }:
import ../sec-agent.nix {
  inherit inputs constants;
  role = "machines-hightrust";
}
