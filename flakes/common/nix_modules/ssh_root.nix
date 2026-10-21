# Root SSH via the fleet nix2nix key, for root deploys (deploy_<host>,
# NIX_SSHOPTS="-i <nix2nix key>"), remote builds and admin from other fleet
# hosts. Pairs with `hardening` (PermitRootLogin = "yes", key-only auth).
{ ... }:
let
  fleet = import ../../../hosts/fleet.nix;
in
{
  users.users.root.openssh.authorizedKeys.keys = [ fleet.global.sshPubKey ];
}
