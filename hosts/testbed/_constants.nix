# Constants for testbed: a throwaway VM of the general fleet config. Not in
# hosts/fleet.nix (never deployed, no tailnet, no secrets).
{
  host = {
    name = "testbed";
    primaryUser = "luser";
    stateVersion = "26.05";
  };
}
