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
          # Network: service.nix net (private, 10.233.16.2). The apps share
          # the guest loopback, so stored URLs (localhost:8989 etc.) still work.
          # NFS can't be idmapped and h004 checks raw uids; existing state is
          # owned by host uids. Container root is host root.
          privateUsers = "no";
          # VPN-Confinement builds the `wg` netns, bridge, wireguard link and
          # nat rules inside the guest netns; `ip netns` needs mounts.
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
              host = "${fleet.global.secretsDir}/us_chi_wg_2026-03-15";
              readOnly = true;
            }
            {
              host = "${fleet.global.secretsDir}/sabnzbd_api_key_2026-07-15";
              readOnly = true;
            }
            {
              host = "${fleet.global.secretsDir}/nzbgeek_api_key_2026-07-15";
              readOnly = true;
            }
          ];
        };
      };
    });
}
