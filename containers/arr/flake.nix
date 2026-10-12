{
  description = "arr: the h001 nixarr media stack as one floating container";

  # Managed with the `containers` CLI (see ../README.md and ./README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs 26.05 (same as h001; sabnzbd configFile = null needs it).
    guestpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixarr.url = "github:rasmus-kirk/nixarr";
    nixarr.inputs.nixpkgs.follows = "guestpkgs";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      nixarr,
      ...
    }:
    let
      containersLib = import ../lib.nix;
      fleet = import ../../hosts/fleet.nix;
      constants = import ../../hosts/h001/_constants.nix { inherit fleet; };
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          specialArgs = { inherit nixarr fleet constants; };
          # Host network, so every port and stored inter-app URL
          # (localhost:8989 etc.) stays as it was on bare metal.
          privateNetwork = false;
          # NFS can't be idmapped and h002 checks raw uids; existing state is
          # owned by host uids. Container root is host root.
          privateUsers = "no";
          # VPN-Confinement builds the `wg` netns, bridge, wireguard link and
          # nat rules in the (shared) host namespace; `ip netns` needs mounts.
          capabilities = [
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
            "CAP_SYS_ADMIN"
          ];
          devices = [
            "/dev/dri"
            "/dev/net/tun"
          ];
          binds = [
            { host = constants.services.nixarr.mediaDir; }
            {
              host = fleet.global.secretsDir;
              readOnly = true;
            }
            # `ip netns add` mounts here; it must be the host's so the
            # namespace outlives nothing and is visible to host tools.
            { host = "/run/netns"; }
          ];
        };
      };
    });
}
