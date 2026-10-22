{
  description = "open-webui: Open WebUI as a floating container";

  # Managed with the `containers` CLI (see ../README.md).

  inputs = {
    extra-container.url = "github:erikarvstedt/extra-container";
    # Host-side extra-container eval must stay on 25.11 (issue #40) ...
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # ... the guest runs h001's 26.05 rev. A guest on a newer unstable rev hits
    # infinite recursion in extra-container's 25.11 host eval, so (like h001)
    # only the open-webui module + package come from the unstable rev h001's
    # open-webui-nixpkgs is locked to. Bump deliberately, after a `cnt backup`.
    guestpkgs.url = "github:nixos/nixpkgs/6fcc160353f63555b560f25588925133c8f61f2a";
    openwebuipkgs.url = "github:nixos/nixpkgs/7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f";
  };

  outputs =
    {
      extra-container,
      nixpkgs,
      guestpkgs,
      openwebuipkgs,
      ...
    }:
    let
      containersLib = import ../lib.nix;
      fleet = import ../../hosts/fleet.nix;
    in
    extra-container.lib.eachSupportedSystem (system: {
      packages.default = extra-container.lib.buildContainers {
        inherit system nixpkgs;
        config = containersLib.mkNixosContainer {
          service = import ./service.nix;
          config = import ./container.nix;
          guestNixpkgs = guestpkgs;
          specialArgs.openwebuipkgs = openwebuipkgs;
          # Network: service.nix net (private).
          binds = [
            {
              host = "${fleet.global.secretsDir}/openwebui_env_2026-03-15";
              container = "/var/secrets/openwebui.env";
              readOnly = true;
            }
          ];
        };
      };
    });
}
